# Ralph Savings Report

Across 1 plan run, Ralph's tool-output optimizations netted **291,504 bytes** (~38,791 tokens) after stored-result readbacks.

Of the tool output Ralph inspected, it trimmed 19.2% before the AI read it (net of stored-result readbacks).

Bytes are measured from actual output differences; token figures are estimated (some or all from a bytes/4-equivalent fallback where actual-text token data was unavailable -- see Data quality below). These are tool-output counterfactuals, not a discount off the billed session tokens below. All Ralph token figures are estimates, never provider-measured billed tokens.

> **Generated file -- do not hand-edit.** Regenerate via `ralph benchmark --write-doc`.

Ralph recorded 240 optimization events across 3,681 tool calls; optimization events are not unique-call coverage.

## Session usage

Actual billed token usage from the session:

| Metric | Count |
| --- | --- |
| Input tokens | 7,219,796 |
| Output tokens | 1,484,644 |
| Cache creation input tokens | 4,480,982 |
| Cache read input tokens | 233,370,621 |
| Prompt bytes | 1,153,352 |
| Tool calls total | 3,681 |

Context reuse: **233,370,621** cache-read tokens (hit ratio **95.2%**). Cache reuse is not counted as savings above.

## Tool output: with vs without Ralph

Estimated tool-output bytes/tokens that would have reached the model with vs without Ralph. 'Actual with Ralph' includes stored-result readbacks that re-consumed tool output.

| Metric | Bytes | Tokens |
| --- | --- | --- |
| Hypothetical without Ralph | 1,520,108 | 499,267 |
| Actual with Ralph | 1,228,604 | 460,476 |
| Net savings | 291,504 | 38,791 |
| Net savings rate | 19.2% | - |

## Unverified historical estimate

A further **563,868 bytes** (~233,854 tokens) across 86 event(s) were recorded by legacy telemetry that predates the inline-candidate baseline. **These are excluded from the savings figures above and should not be quoted.**

Legacy records measure savings against the full stored source rather than against what would actually have been inlined. Tool-level limits (grep's `head_limit`, read's `maxReadBytes`, the result byte caps) would have trimmed most of that source before the model ever saw it, so crediting all of it as "saved" systematically overstates the benefit. The true baseline is not recoverable from these records -- which is why the v2 measurement exists. The number is shown to make the gap visible, not to be added to the headline.

## Hook status by runtime

| Runtime | Channel | Status | Reasons |
| --- | --- | --- | --- |
| codex | bash_compact | enabled | runtime_cannot_mutate_output |
| codex | bash_rewrite | disabled | gate_disabled |
| codex | native_result_compact | enabled | runtime_cannot_mutate_output |
| codex | proxy_shell_compact | enabled | proven_channel:explicit_env |
| cursor | bash_compact | enabled | runtime_cannot_mutate_output |
| cursor | bash_rewrite | disabled | gate_disabled |
| cursor | native_result_compact | enabled | runtime_cannot_mutate_output |
| cursor | proxy_shell_compact | enabled | proven_channel:explicit_env |

## Result windowing by source tool

| Tool | Events | Inline candidate bytes | Delivered bytes | Net consumed bytes | Net saved bytes | Source-capped | Quality |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bash | 86 | 857,688 | 233,958 | 293,820 | 563,868 | 0 | legacy |
| ralph_proxy_glob | 4 | 36,961 | 41,665 | 41,665 | -4,704 | 0 | v2 |
| ralph_proxy_grep | 70 | 667,354 | 676,043 | 676,043 | -8,689 | 1 | v2 |
| ralph_proxy_read | 30 | 294,176 | 298,275 | 322,031 | -27,855 | 0 | v2 |

## Source-capped search operations

**1** source search(es) stopped early after hitting a source cap; **258,997** bytes were captured/stored across them.

| Cap reason | Count |
| --- | --- |
| byte_cap | 1 |

Configured byte-cap limit(s) observed: 262,144.

Uncaptured/avoided source bytes beyond these caps are unknown -- collection stopped early -- and are not added to any token/context savings figure above.

## Data quality

- Token-figure quality: **legacy_or_mixed** -- some or all token counterfactuals used a bytes/4-equivalent fallback rather than an estimate over actual text.

## Optimization by channel

Exact channel attribution shows where tool-output savings came from. Gross readback is diagnostic follow-up cost; net consumed is the decision-grade bytes agents actually re-read after windowing.

### Exact attribution

| Channel | Attribution | Saved bytes | Saved tokens | Gross readback | Net consumed |
| --- | --- | --- | --- | --- | --- |
| Native shell hook compaction | exact | 550,916 | 226,452 | 59,862 | 293,820 |
| Proxy shell compaction | exact | 444,337 | 111,085 | - | - |
| Proxy read windowing | exact | 28,944 | 8,107 | 23,756 | 322,031 |
| Proxy search windowing | exact | 78,735 | 28,520 | - | 676,043 |

### Legacy / unknown attribution

Historical runs without channel metadata are grouped here. Treat these totals as approximate until a new run records exact channels.

| Channel | Attribution | Saved bytes | Saved tokens | Gross readback | Net consumed |
| --- | --- | --- | --- | --- | --- |
| Stored result readback | legacy (unknown) | - | - | - | 41,665 |

## Per run

| Run | Date | Gross trim % | Net savings % | Without Ralph bytes | With Ralph bytes |
| --- | --- | --- | --- | --- | --- |
| PLAN2.plan | 2026-07-13T17:40:36Z to 2026-07-14T23:14:59Z | 36.0% | 19.2% | 1,520,108 | 1,228,604 |

## Stored result follow-ups

Result windowing sends a compact preview; follow-up reads add bytes back. Effective windowing savings rate is the decision-grade net signal after capping readbacks at the original envelope size.

- Envelopes: **190**; readbacks: **19** (compacted **4**, raw **15**). Full preview re-reads: **6**.
- Gross follow-up reads: **121,613 bytes** (~45,168 tokens); net consumed: **1,333,559 bytes** (~526,798 tokens).
- Effective windowing savings rate: **28.2%** of original envelope bytes (net of capped readbacks).
- Raw readback share: **79.0%** of follow-up reads; diagnostic gross negation rate: **6.6%** of envelope original bytes.

## Improvement opportunities

Guidance sourced from the most recent eligible run: `PLAN2.plan` at 2026-07-14T23:14:59Z.

Usage pattern opportunities:
- `native_read_after_grep`: Native read immediately after grep in tool_calls_sequence
- `repeated_native_read_like`: Consecutive native read/search tool calls in tool_calls_sequence

Stored result usage: 6 full stored-result reread(s); 15 raw result_read follow-up(s); treat inline preview as sufficient, use result_search or compacted byte ranges before view=raw; avoid full preview re-reads

## How to read this

- **Session usage** shows cumulative billed tokens (input/output/cache) from the plan run (these are the actual API call totals across all invocations). This is independent of the estimated tool-output counterfactuals below.
- **Tool output: with vs without Ralph** estimates the bytes/tokens that would have reached the model from tool output if Ralph had not trimmed it. These are counterfactual estimates of what the model would have ingested, not a discount off the billed session input tokens above. 'Actual with Ralph' includes follow-up stored-result readbacks, so heavy rereads can drive net savings toward zero even when previews were compact.
- **Optimization by channel** is the authoritative breakdown of where savings came from. Exact channels come from runtime telemetry; legacy/unknown rows reflect historical runs without channel metadata.
- **Net savings** (in the Tool output table) is the estimated reduction in bytes/tokens sent to the model after Ralph's optimizations. This is measured from tool-output differences only, not from the billed session usage totals.
- **Stored result follow-ups** distinguishes gross re-read bytes (diagnostic) from net effective windowing savings. A high gross negation rate is expected when agents escalate to raw or full-preview views.
- **Why savings are low** prints root causes only when the net savings rate is near 0%: inactive paths, readback-negated windowing, or compaction measured but not applied.
- This report does not measure end-to-end wall-clock speedup.

Date range: 2026-07-13T17:40:36Z to 2026-07-14T23:14:59Z.
