# Ralph Savings Report

Across 48 plan runs, Ralph's tool-output optimizations netted **1,156,762 bytes** (~289,222 tokens) after stored-result readbacks.

Of the tool output Ralph inspected, it trimmed 82.4% before the AI read it (net of stored-result readbacks).

Bytes are measured from actual output differences; token figures are estimated (some or all from a bytes/4-equivalent fallback where actual-text token data was unavailable -- see Data quality below). These are tool-output counterfactuals, not a discount off the billed session tokens below. All Ralph token figures are estimates, never provider-measured billed tokens.

> **Generated file -- do not hand-edit.** Regenerate via `ralph benchmark --write-doc`.

Ralph recorded 380 optimization events across 21,372 tool calls; optimization events are not unique-call coverage.

## Session usage

Actual billed token usage from the session:

| Metric | Count |
| --- | --- |
| Input tokens | 370,088,276 |
| Output tokens | 6,145,420 |
| Cache creation input tokens | 9,188,020 |
| Cache read input tokens | 832,373,783 |
| Prompt bytes | 3,139,916 |
| Tool calls total | 21,372 |

Context reuse: **832,373,783** cache-read tokens (hit ratio **68.7%**). Cache reuse is not counted as savings above.

## Tool output: with vs without Ralph

Estimated tool-output bytes/tokens that would have reached the model with vs without Ralph. 'Actual with Ralph' includes stored-result readbacks that re-consumed tool output.

| Metric | Bytes | Tokens |
| --- | --- | --- |
| Hypothetical without Ralph | 1,404,585 | 351,347 |
| Actual with Ralph | 247,823 | 62,125 |
| Net savings | 1,156,762 | 289,222 |
| Net savings rate | 82.4% | - |

**Measured but not applied:** 70,816 bytes of compaction savings were measured but unavailable in this runtime mode (for example, native-mode runs without Ralph proxy).

## Unverified historical estimate

A further **1,123,629,262 bytes** (~183,254,147 tokens) across 265 event(s) were recorded by legacy telemetry that predates the inline-candidate baseline. **These are excluded from the savings figures above and should not be quoted.**

Legacy records measure savings against the full stored source rather than against what would actually have been inlined. Tool-level limits (grep's `head_limit`, read's `maxReadBytes`, the result byte caps) would have trimmed most of that source before the model ever saw it, so crediting all of it as "saved" systematically overstates the benefit. The true baseline is not recoverable from these records -- which is why the v2 measurement exists. The number is shown to make the gap visible, not to be added to the headline.

## Hook status by runtime

unknown (no config record)

## Result windowing by source tool

| Tool | Events | Inline candidate bytes | Delivered bytes | Net consumed bytes | Net saved bytes | Source-capped | Quality |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ralph_proxy_glob | 3 | 18,571 | 14,670 | 14,670 | 3,901 | 0 | legacy |
| ralph_proxy_grep | 43 | 2,126,063 | 356,487 | 365,864 | 1,760,199 | 0 | legacy |
| ralph_proxy_read | 60 | 534,562 | 493,275 | 616,429 | -81,867 | 0 | legacy |
| ralph_proxy_shell | 1 | 16,889 | 438 | 438 | 16,451 | 0 | legacy |

> **Caution:** a single result-windowing event from **ralph_proxy_grep** (legacy measurement) accounts for **57.1%** of total attributed net windowing savings. Treat the headline savings rate as sensitive to this one event.

## Data quality

- Token-figure quality: **legacy_or_mixed** -- some or all token counterfactuals used a bytes/4-equivalent fallback rather than an estimate over actual text.
- **1** run summary file(s) were malformed or unreadable and were skipped (excluded from all totals above).
- **17** unattributed telemetry group(s) (mismatched, fallback-marked, or missing plan key) were excluded from savings totals above as diagnostics only:

  | Log kind | Observed key | Fallback | Count | Bytes |
  | --- | --- | --- | --- | --- |
  | bash_compact | hook-fixture-bats-large | no | 2 | 814 |
  | bash_compact | hook-fixture-grep | no | 2 | 280 |
  | bash_compact | plan29-proxy-tools | no | 104 | 34,527 |
  | bash_compact | plan33-mcp-server-rewrite | no | 1 | 213 |
  | bash_compact | plan33-shell-rewrite | no | 5 | 895 |
  | result_windowing | claude-hooks-test | no | 102 | 2,040,000 |
  | result_windowing | cursor-hooks-test | no | 20 | 400,000 |
  | result_windowing | mcp-server-grep-envelope | no | 3 | 24,873 |
  | result_windowing | mcp-server-read-envelope | no | 3 | 24,147 |
  | result_windowing | mcp-server-shell-envelope | no | 3 | 1,500 |
  | result_windowing | opencode-native-result-test | no | 328 | 12,035,706 |
  | result_windowing | plan-batch-proxy | no | 62 | 0 |
  | result_windowing | plan-result-read-source | no | 2 | 0 |
  | result_windowing | plan-search-dedupe | no | 1,071 | 7,809,492 |
  | result_windowing | plan55-proxy-repomap | no | 90 | 9,810 |
  | result_windowing | plan55-proxy-search | no | 92 | 7,084 |
  | result_windowing | test | no | 28 | 1,234,799 |

## Optimization by channel

Exact channel attribution shows where tool-output savings came from. Gross readback is diagnostic follow-up cost; net consumed is the decision-grade bytes agents actually re-read after windowing.

### Exact attribution

| Channel | Attribution | Saved bytes | Saved tokens | Gross readback | Net consumed |
| --- | --- | --- | --- | --- | --- |
| Proxy shell compaction | exact | 1,331,641 | 332,911 | - | - |
| Native result hook compaction | exact | 70,842 | 17,712 | - | - |

### Legacy / unknown attribution

Historical runs without channel metadata are grouped here. Treat these totals as approximate until a new run records exact channels.

| Channel | Attribution | Saved bytes | Saved tokens | Gross readback | Net consumed |
| --- | --- | --- | --- | --- | --- |
| Stored result readback | legacy (unknown) | 1,123,531,586 | 183,198,147 | 298,351 | 2,905,753 |

## Per run

| Run | Date | Gross trim % | Net savings % | Without Ralph bytes | With Ralph bytes |
| --- | --- | --- | --- | --- | --- |
| PLAN15-compaction-telemetry-hardening.plan | 2026-07-11T05:29:58Z to 2026-07-11T05:47:37Z | 0.0% | 0.0% | 0 | 0 |
| benchmark-channel-attribution.plan | 2026-07-05T04:18:01Z to 2026-07-05T05:02:42Z | 30.2% | 0.0% | 0 | 0 |
| PLAN | 2026-06-11T18:56:29Z to 2026-07-03T17:45:09Z | 0.0% | 0.0% | 0 | 0 |
| PLAN14.plan | 2026-06-30T18:55:37Z to 2026-06-30T20:05:37Z | 56.5% | 0.0% | 0 | 0 |
| token-usage-remediation.plan | 2026-06-27T05:40:52Z to 2026-06-27T22:00:28Z | 97.7% | 91.3% | 4,346 | 378 |
| PLAN-MCP-STABILIZE.plan | 2026-06-24T20:47:36Z to 2026-06-24T21:32:48Z | 0.0% | 0.0% | 0 | 0 |
| PLAN13.plan | 2026-06-24T15:34:08Z to 2026-06-24T18:41:57Z | 97.5% | 0.0% | 0 | 0 |
| PLAN12.plan | 2026-06-23T13:58:49Z to 2026-06-24T03:24:12Z | 0.0% | 0.0% | 0 | 0 |
| fix-ctrlc-teardown.plan | 2026-06-22T03:06:11Z to 2026-06-22T15:49:15Z | 0.0% | 0.0% | 0 | 0 |
| proxy-permission-escalate.plan | 2026-06-20T04:03:03Z to 2026-06-21T03:06:29Z | 0.0% | 0.0% | 0 | 0 |
| runner-owned-long-jobs.plan | 2026-06-20T03:07:57Z to 2026-06-20T03:57:36Z | 0.0% | 0.0% | 0 | 0 |
| PLAN10.plan | 2026-06-19T03:50:48Z to 2026-06-19T05:29:51Z | 0.0% | 0.0% | 0 | 0 |
| PLAN9.plan | 2026-06-18T03:48:22Z to 2026-06-19T01:31:31Z | 55.1% | 66.3% | 9,865 | 3,320 |
| benchmark-report-overhaul.plan | 2026-06-17T22:12:20Z to 2026-06-17T23:49:29Z | -40.8% | 0.0% | 0 | 0 |
| PLAN8.plan | 2026-06-17T18:24:29Z to 2026-06-17T21:44:40Z | 3.1% | 27.9% | 3,935 | 2,836 |
| PROSE.plan | 2026-06-17T20:32:33Z to 2026-06-17T20:32:34Z | 0.0% | 0.0% | 0 | 0 |
| agent-source-resolver.plan | 2026-06-17T06:02:13Z to 2026-06-17T17:09:00Z | 20.6% | 91.9% | 110,070 | 8,915 |
| antigravity-support.plan | 2026-06-16T04:45:11Z to 2026-06-16T21:12:38Z | 99.9% | 71.2% | 273,730 | 78,788 |
| antigravity-smoke | 2026-06-16T19:17:11Z to 2026-06-16T20:24:24Z | 0.0% | 0.0% | 0 | 0 |
| dual-view-agent-guidance.plan | 2026-06-16T05:22:00Z to 2026-06-16T05:29:03Z | 47.5% | 0.0% | 0 | 0 |
| async-shell-wait-and-status-hardening.plan | 2026-06-15T16:03:31Z to 2026-06-16T01:23:16Z | 99.7% | 64.2% | 125,298 | 44,823 |
| verification-reopen-retry-hardening.plan | 2026-06-15T19:40:06Z to 2026-06-15T23:23:34Z | 44.9% | 82.8% | 80,657 | 13,864 |
| benchmark-report-clarity.plan | 2026-06-15T05:02:16Z to 2026-06-15T16:17:05Z | 96.4% | 89.7% | 461,904 | 47,805 |
| hybrid-knobs-implementation | 2026-06-15T03:51:53Z to 2026-06-15T04:50:15Z | 43.9% | 56.8% | 10,177 | 4,399 |
| PLAN6.plan | 2026-06-13T02:43:02Z to 2026-06-15T04:07:34Z | 0.0% | 0.0% | 0 | 0 |
| tui-output-improvements.plan | 2026-06-14T19:16:12Z to 2026-06-14T22:00:39Z | 99.9% | 88.3% | 229,389 | 26,759 |
| small.plan | 2026-06-14T20:22:32Z to 2026-06-14T20:22:34Z | 0.0% | 0.0% | 0 | 0 |
| savings-feature.plan | 2026-06-14T15:55:02Z to 2026-06-14T17:51:43Z | 57.1% | 76.2% | 11,256 | 2,684 |
| TOOL-IMPROVEMENTS.plan | 2026-06-14T04:57:23Z to 2026-06-14T15:49:35Z | 0.0% | 0.0% | 0 | 0 |
| other-plan | 2026-06-14T11:00:00Z to 2026-06-14T11:01:00Z | 20.0% | 20.0% | 250 | 200 |
| savings-report | 2026-06-14T10:00:00Z to 2026-06-14T10:01:00Z | 18.8% | 18.8% | 800 | 650 |
| BENCHMARKS-REPORT.plan | 2026-06-14T04:25:37Z to 2026-06-14T04:45:33Z | 0.0% | 0.0% | 0 | 0 |
| structured-pipeline-plans.plan | 2026-06-12T14:22:08Z to 2026-06-12T23:08:03Z | -4.3% | -4.3% | 93 | 97 |
| artifact-plan | 2026-06-12T16:51:42Z to 2026-06-12T16:51:43Z | 0.0% | 0.0% | 0 | 0 |
| codex-live-smoke | 2026-06-12T12:26:44Z to 2026-06-12T12:28:10Z | 0.0% | 0.0% | 0 | 0 |
| codex-tui-and-full-auto.plan | 2026-06-12T03:56:25Z to 2026-06-12T12:25:05Z | 98.2% | 98.2% | 2,144 | 38 |
| tool-use-followups.plan | 2026-06-12T00:41:44Z to 2026-06-12T04:35:39Z | 0.0% | 0.0% | 0 | 0 |
| opencode-prompt-cache-key.plan | 2026-06-11T20:50:51Z to 2026-06-11T23:07:54Z | 93.8% | 93.8% | 61,053 | 3,798 |
| tool-use-optimization.plan | 2026-06-11T18:35:50Z to 2026-06-11T20:24:57Z | 0.0% | 0.0% | 0 | 0 |
| mcp-proxy-operator-approvals.plan | 2026-06-11T16:33:56Z to 2026-06-11T17:21:00Z | 0.0% | 0.0% | 0 | 0 |
| PLAN4 | 2026-06-11T14:40:46Z to 2026-06-11T15:36:26Z | -18.9% | -18.9% | 566 | 673 |
| fix-ralph-workspace-boundaries.plan | 2026-06-10T15:23:12Z to 2026-06-11T04:26:12Z | 59.1% | 59.1% | 19,052 | 7,796 |
| setup-runtime.plan | 2026-06-11T03:01:15Z to 2026-06-11T04:00:17Z | 0.0% | 0.0% | 0 | 0 |
| PLAN3.plan | 2026-06-10T23:24:00Z to 2026-06-11T00:31:34Z | 0.0% | 0.0% | 0 | 0 |
| PLAN2 | 2026-06-10T23:23:10Z to 2026-06-11T00:17:26Z | 0.0% | 0.0% | 0 | 0 |
| PLAN1.plan | 2026-06-10T18:57:47Z to 2026-06-10T19:00:02Z | 0.0% | 0.0% | 0 | 0 |
| preflight-fail.plan | 2026-06-10T16:30:43Z to 2026-06-10T16:30:44Z | 0.0% | 0.0% | 0 | 0 |
| fix-bats-regressions.plan | 2026-06-10T14:23:00Z to 2026-06-10T14:33:44Z | 0.0% | 0.0% | 0 | 0 |

## Stored result follow-ups

Result windowing sends a compact preview; follow-up reads add bytes back. Effective windowing savings rate is the decision-grade net signal after capping readbacks at the original envelope size.

- Envelopes: **139**; readbacks: **120** (compacted **78**, raw **42**). Full preview re-reads: **35**.
- Gross follow-up reads: **430,454 bytes** (~144,304 tokens); net consumed: **1,176,185 bytes** (~418,713 tokens).
- Effective windowing savings rate: **57.6%** of original envelope bytes (net of capped readbacks).
- Raw readback share: **35.0%** of follow-up reads; diagnostic gross negation rate: **15.5%** of envelope original bytes.

## Improvement opportunities

Guidance sourced from the most recent eligible run: `PLAN15-compaction-telemetry-hardening.plan` at 2026-07-11T05:47:37Z.

Missed compaction opportunities:
- `compaction skipped` (0 bytes)

Usage pattern opportunities:
- `repeated_native_read_like`: Consecutive native read/search tool calls in tool_calls_sequence

Native read findings:
- `heavy_native_read_no_proxy`: 100.0% of read-like calls were native reads.

## How to read this

- **Session usage** shows cumulative billed tokens (input/output/cache) from the plan run (these are the actual API call totals across all invocations). This is independent of the estimated tool-output counterfactuals below.
- **Tool output: with vs without Ralph** estimates the bytes/tokens that would have reached the model from tool output if Ralph had not trimmed it. These are counterfactual estimates of what the model would have ingested, not a discount off the billed session input tokens above. 'Actual with Ralph' includes follow-up stored-result readbacks, so heavy rereads can drive net savings toward zero even when previews were compact.
- **Optimization by channel** is the authoritative breakdown of where savings came from. Exact channels come from runtime telemetry; legacy/unknown rows reflect historical runs without channel metadata.
- **Net savings** (in the Tool output table) is the estimated reduction in bytes/tokens sent to the model after Ralph's optimizations. This is measured from tool-output differences only, not from the billed session usage totals.
- **Stored result follow-ups** distinguishes gross re-read bytes (diagnostic) from net effective windowing savings. A high gross negation rate is expected when agents escalate to raw or full-preview views.
- **Why savings are low** prints root causes only when the net savings rate is near 0%: inactive paths, readback-negated windowing, or compaction measured but not applied.
- This report does not measure end-to-end wall-clock speedup.

Date range: 2026-06-10T14:23:00Z to 2026-07-11T05:47:37Z.
