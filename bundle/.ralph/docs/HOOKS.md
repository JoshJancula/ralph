# Output-shaping hooks: single source of truth

This file is the permanent reference for every hook Ralph installs that shapes,
rewrites, or compacts tool output (or nudges a tool call before/after it runs).
It exists so this layer never has to be reverse-engineered from source again.
See [docs/TOOLING.md](TOOLING.md) for the higher-level explanation of Ralph
mode, MCP compaction, and native adapters; this file documents the exact hook
scripts, their gates, and their fail-open behavior.

All hooks read JSON on stdin and are fail-open: any missing dependency
(`jq`, `python3`), malformed input, wrong event/tool match, or disabled gate
causes the hook to exit 0 without altering the tool call. None of these hooks
can block a tool call except `block-env-reads.sh`, which is a deliberate
policy denial, not a compaction failure path.

## Hook inventory

| File | Runtime | Hook event | Tool matcher | Env var (default) | Behavior (one sentence) | Fail-open behavior |
|------|---------|------------|---------------|--------------------|-------------------------|---------------------|
| `bundle/.claude/hooks/compact-bash-output.sh` | Claude | `PostToolUse` | `Bash` | `RALPH_BASH_COMPACT` (on by default under Ralph native\|hybrid via `run-plan-args.sh` when unset; `RALPH_BASH_COMPACT=0` opts out) | Runs the shared shell-output compactor on successful Bash stdout/stderr, stores the original, and replaces `tool_response` via `hookSpecificOutput.updatedToolOutput`, appending a stored-result footer. | Exits 0 (leaves output untouched) on missing `jq`, wrong event/tool, malformed `tool_response`, missing compactor library, or `RALPH_BASH_COMPACT` falsy; only fires on successful (exit 0) Bash calls because Claude does not deliver `tool_response` on failures. |
| `bundle/.claude/hooks/rewrite-bash-command.sh` | Claude | `PreToolUse` | `Bash` | `RALPH_BASH_REWRITE` (default off) | Runs the shared command-rewriter registry against `tool_input.command` and, if a rule applies, replaces the command via `hookSpecificOutput.updatedInput` before execution; also evaluates the killswitch policy (gated separately by `RALPH_MODE`, not by `RALPH_BASH_REWRITE`) on every Bash call regardless of the rewrite gate. | Exits 0 (command runs unchanged) on missing `jq`/`python3`, wrong event/tool, empty command, missing rewriter library, no matching rule, or `RALPH_BASH_REWRITE` falsy. |
| `bundle/.claude/hooks/native-result-compact.sh` | Claude | `PostToolUse` | `Read\|Grep\|Glob` | `RALPH_NATIVE_RESULT_COMPACT` (default off; explicit opt-in) | Delegates to the shared `post-tool-native-result-compact-hook.sh`, which compacts Read/Grep/Glob output through the same envelope/store path as MCP proxy results and replaces the tool output. | Exits 0 (leaves output untouched) when the shared hook script is missing, when `RALPH_NATIVE_RESULT_COMPACT` is not explicitly truthy, or on any internal failure; `RALPH_BASH_COMPACT` truthiness does **not** enable this path (source-bearing Read/Grep/Glob output has a different safety contract than Bash stdout). |
| `bundle/.claude/hooks/block-env-reads.sh` | Claude | `PreToolUse` | `Read\|Edit\|MultiEdit\|Glob\|Grep\|LS` | none (always active; not gated by an env var) | Inspects `path`/`file_path`/`filename` in the tool input and blocks (exit 1, stderr message) any call whose basename starts with `.env`. | This hook fails open only on missing/unmatched input (no path found -> allow); when it does match a `.env*` basename it deliberately blocks (exit 1) rather than fails open, because blocking secret reads is the point of the hook. |
| `bundle/.claude/hooks/stop-continuation.sh` | Claude | `Stop` | n/a (Stop hooks are not tool-scoped) | none directly; the underlying core respects `RALPH_BG_JOBS` / background-job state | Waits for Ralph background jobs registered against the run and blocks the Stop event with a reason (forcing another turn) while jobs remain outstanding. | Exits 0 (lets Claude stop normally) on missing `jq`, unresolved project directory, or missing adapter/core scripts. |
| `bundle/.cursor/hooks/pre-tool-shell-policy.sh` | Cursor / Antigravity (`.agents/hooks`) | `preToolUse` | `Shell` | `RALPH_NATIVE_SHELL_WRAPPER` (default on when Ralph enables Cursor native hooks) with `RALPH_BASH_REWRITE` (default off) as the fallback path | Evaluates the killswitch, then either wraps the command through the shared native-shell-wrapper (captures/compacts output, stores originals) when `RALPH_NATIVE_SHELL_WRAPPER` is truthy, or applies a plain command-rewrite when only `RALPH_BASH_REWRITE` is truthy, and emits `updated_input.command`. | Exits 0 (command runs unchanged) on missing `jq`/`python3`, wrong event/tool, empty command, unresolved workspace, missing rewriter library, both gates off, or no rule match. |
| `bundle/.cursor/hooks/pre-tool-exploration-policy.sh` | Cursor / Antigravity | `preToolUse` | `Read\|read\|readToolCall\|Grep\|grep\|grepToolCall\|Glob\|glob\|globToolCall\|SemanticSearch\|semanticSearch` | `RALPH_NATIVE_EXPLORATION_NUDGE` (default derives from strict Ralph mode; `=1` forces on, `=0` opts out) | In strict `ralph` mode (native hooks off), denies native Read/Grep/Glob/SemanticSearch so the agent is nudged toward `ralph_proxy_*` MCP tools instead; native Read is allowed only for paths recently handed off by `pre-tool-proxy-read-handoff.sh`. | Exits 0 (allows the native call) when not in strict mode, when the nudge is explicitly disabled, or on any internal failure. |
| `bundle/.cursor/hooks/pre-tool-proxy-read-handoff.sh` | Cursor / Antigravity | `preToolUse` | `MCP:ralph_proxy_read` | `RALPH_NATIVE_EXPLORATION_NUDGE` (same gate as the exploration policy above) | Records the path just read via `ralph_proxy_read` so the immediately following native Read on that same path is allowed through `pre-tool-exploration-policy.sh` (supports the proxy-read -> native-Read -> Edit flow). | Exits 0 (records nothing, no effect on the next call) when the nudge gate is off or on any internal failure. |
| `bundle/.cursor/hooks/post-tool-shell-telemetry.sh` | Cursor / Antigravity | `postToolUse` | `Shell` | `RALPH_BASH_TELEMETRY_LOG` (unset by default; observability only) | Appends a JSONL audit line (byte counts, command hash) to the configured telemetry log; does **not** attempt output replacement because Cursor's `updated_tool_output` is proven not to change agent-visible Shell stdout. | Exits 0 always; missing `jq` or unset `RALPH_BASH_TELEMETRY_LOG` simply skips logging. |
| `bundle/.cursor/hooks/post-tool-native-result-compact.sh` | Cursor / Antigravity | `postToolUse` | `Read\|read\|readToolCall\|Grep\|grep\|grepToolCall\|Glob\|glob\|globToolCall\|SemanticSearch\|semanticSearch` | `RALPH_NATIVE_RESULT_COMPACT` (default off; explicit opt-in) | Delegates to the same shared `post-tool-native-result-compact-hook.sh` used by Claude/Codex to compact native exploration output and replace it via `updated_tool_output`. | Exits 0 (leaves output untouched) when the shared hook is missing, the gate is off, or on any internal failure. |
| `bundle/.cursor/hooks/pre-tool-proxy-read-handoff.sh` / `post-tool-mcp-compact.sh` | Cursor / Antigravity | `postToolUse` | `MCP:*` (scoped internally to `ralph_proxy_*`) | `RALPH_CURSOR_MCP_HOOK_COMPACT` (explicit override) falling back to `RALPH_PROXY_SHELL_COMPACT` (default off) | Compacts Ralph MCP proxy tool results that exceed the per-tool byte cap and replaces them via `updated_mcp_tool_output`, storing the original for later retrieval; records windowing telemetry when the shared telemetry lib is present. **Only `ralph_proxy_*` tools are ever touched; third-party MCP results pass through unchanged.** | Exits 0 (leaves the MCP result untouched) when disabled, the tool isn't a `ralph_proxy_*` tool, the result is already an envelope, the result is under the byte cap, or any library fails to load. |
| `bundle/.cursor/hooks/after-shell-telemetry.sh` | Cursor / Antigravity | `afterShellExecution` | n/a (fires for every shell execution) | duration learning always (no env gate); `RALPH_BASH_TELEMETRY_LOG` (unset by default) for optional audit lines | Records shell duration from the payload's documented `duration` field into the shared `command_profiles` store; optionally appends a one-line audit record when the telemetry log path is set. | Exits 0 always; missing `jq`/workspace/python skips learning silently; unset `RALPH_BASH_TELEMETRY_LOG` skips only the audit line. |
| `bundle/.cursor/hooks/stop-continuation.sh` | Cursor / Antigravity | `stop` | n/a | none directly; underlying core respects background-job state | Same background-job wait/block behavior as the Claude Stop hook, adapted for Cursor's `stop` hook shape (`loop_limit: 5` in `hooks.json`). | Exits 0 (lets the run stop normally) on missing dependencies or unresolved project directory. |
| `bundle/.codex/hooks/pre-tool-bash-policy.sh` | Codex | `PreToolUse` | `Bash` / `command_execution` | `RALPH_NATIVE_SHELL_WRAPPER` (default on when Ralph enables Codex native hooks) with `RALPH_BASH_REWRITE` (default off) as the fallback path | Evaluates the killswitch, marks an inflight start timestamp keyed by `tool_use_id` for duration pairing (Codex PostToolUse has no elapsed-time field), then wraps the command through the native-shell-wrapper when `RALPH_NATIVE_SHELL_WRAPPER` is truthy, or falls back to a plain command-rewrite when only `RALPH_BASH_REWRITE` is truthy, emitting `hookSpecificOutput.updatedInput.command`. | Exits 0 (command runs unchanged) on missing `jq`/`python3`, wrong event/tool, empty command, unresolved workspace, or no rewrite/wrapper produced; inflight mark failures are silent. |
| `bundle/.codex/hooks/post-tool-bash-telemetry.sh` | Codex | `PostToolUse` | `Bash` / `command_execution` | duration learning always (no env gate); `RALPH_BASH_TELEMETRY_LOG` (unset by default) for optional audit lines | Completes pre/post inflight duration pairing (Codex PostToolUse has no `duration_ms`); optionally appends a JSONL audit line (`compactionSkipped: true`) because Codex's model-visible PostToolUse output mutation is unproven on the current CLI build. | Exits 0 always; missing `jq`/python skips learning silently; unset `RALPH_BASH_TELEMETRY_LOG` skips only the audit line. |
| `bundle/.codex/hooks/post-tool-native-result-compact.sh` | Codex | `PostToolUse` | `read_file\|grep\|Glob\|Read\|Grep` | `RALPH_NATIVE_RESULT_COMPACT` (default off; explicit opt-in) | Delegates to the same shared `post-tool-native-result-compact-hook.sh` used by Claude/Cursor to compact native read/grep/glob output. | Exits 0 (leaves output untouched) when the shared hook is missing, the gate is off, or on any internal failure. |
| `bundle/.opencode/plugins/ralph-runtime-hooks.ts` / `.mjs` | OpenCode | `tool.execute.before`, `tool.execute.after` (OpenCode plugin lifecycle hooks, not settings-file hooks) | `bash` (rewrite + compaction + duration pairing); `read\|grep\|glob\|search\|bash` (exploration result compaction) | `RALPH_BASH_REWRITE` (default off) for the pre-tool rewrite; `RALPH_NATIVE_RESULT_COMPACT` / `RALPH_BASH_COMPACT` / `RALPH_PROXY_SHELL_COMPACT` (see precedence below) for post-tool compaction; `RALPH_BASH_TELEMETRY_LOG` (unset by default) for telemetry | Before execution, marks an inflight start for `bash` (OpenCode after-hook has no duration field; keyed by `callID`) and optionally rewrites via the shared Python rewriter when `RALPH_BASH_REWRITE` is truthy; after execution, completes inflight pairing into `command_profiles`, then compacts `bash`/exploration output when enabled and appends telemetry when `RALPH_BASH_TELEMETRY_LOG` is set. Headless model-visible mutation via this plugin path is unproven on the current OpenCode build (see `SPIKE-output-mutation.md`); MCP proxy compaction remains the reliable path. | On any spawn failure, non-zero exit from the Python/bash helper, or JSON parse failure, the plugin returns the original command/output unchanged (no exception propagates to the tool call); the `.ts` file is the typed source and the `.mjs` file is the plain-JS twin actually loaded at runtime, kept behaviorally identical. |

## Measured hook latency

Re-measure with `bash scripts/hook-latency.sh` (default N=5). Payloads are derived from
the small fixtures under `tests/fixtures/native-hook/`. OpenCode's plugin is listed as
n/a because it is not a stdin bash hook.

### F5 baseline (pre Part E)

From the COMPACTION-CACHE-AUDIT plan overview (F5), 5-run mean on this machine class,
payload `echo hi` / tiny Read -- the numbers Part E set out to improve:

| Hook | unset | hybrid / notes |
|------|-------|----------------|
| claude `compact-bash-output.sh` | 830 ms | (even for 3-byte output) |
| claude `rewrite-bash-command.sh` | 459 ms | 1423 ms `RALPH_MODE=hybrid` |
| claude `block-env-reads.sh` | 124 ms | (every Read) |
| claude/cursor `post-tool-native-result` | 174-180 ms | (feature OFF) |
| cursor `pre-tool-shell-policy.sh` | 296 ms | 1307 ms hybrid+wrapper |
| cursor `post-tool-shell-telemetry.sh` | 113 ms | |
| cursor `pre-tool-exploration-policy.sh` | 101 ms | (feature OFF) |

### Current measurement

- Date: 2026-09-11
- Machine: Darwin x86_64 (MacBookPro18,2 / Apple M1 Max)
- Runs per cell: 5
- Env states: `RALPH_MODE` unset; `RALPH_MODE=hybrid`; `RALPH_MODE=hybrid` + every
  compaction channel on (`RALPH_BASH_COMPACT`, `RALPH_BASH_REWRITE`,
  `RALPH_NATIVE_RESULT_COMPACT`, `RALPH_NATIVE_SHELL_WRAPPER`,
  `RALPH_PROXY_SHELL_COMPACT` / `RALPH_CURSOR_MCP_HOOK_COMPACT`,
  `RALPH_COMPACT_GENERIC_FALLBACK`, `RALPH_BASH_TELEMETRY_LOG`)

| Hook | unset (ms) | hybrid (ms) | hybrid+all compact (ms) |
|------|------------|-------------|-------------------------|
| `bundle/.claude/hooks/compact-bash-output.sh` | 26.6 | 26.7 | 67.5 |
| `bundle/.claude/hooks/rewrite-bash-command.sh` | 120.8 | 146.8 | 330.0 |
| `bundle/.claude/hooks/native-result-compact.sh` | 26.8 | 26.5 | 1158.8 |
| `bundle/.claude/hooks/block-env-reads.sh` | 28.2 | 27.9 | 27.9 |
| `bundle/.claude/hooks/stop-continuation.sh` | 253.3 | 244.8 | 250.2 |
| `bundle/.cursor/hooks/pre-tool-shell-policy.sh` | 117.2 | 140.3 | 411.1 |
| `bundle/.cursor/hooks/pre-tool-exploration-policy.sh` | 74.7 | 74.5 | 74.9 |
| `bundle/.cursor/hooks/pre-tool-proxy-read-handoff.sh` | 75.1 | 77.2 | 87.6 |
| `bundle/.cursor/hooks/post-tool-shell-telemetry.sh` | 87.0 | 87.3 | 612.8 |
| `bundle/.cursor/hooks/post-tool-native-result-compact.sh` | 29.2 | 26.0 | 1315.1 |
| `bundle/.cursor/hooks/post-tool-mcp-compact.sh` | 88.4 | 78.9 | 4097.0 |
| `bundle/.cursor/hooks/after-shell-telemetry.sh` | 330.9 | 334.0 | 442.0 |
| `bundle/.cursor/hooks/stop-continuation.sh` | 248.5 | 248.2 | 244.6 |
| `bundle/.codex/hooks/pre-tool-bash-policy.sh` | 136.7 | 175.8 | 439.5 |
| `bundle/.codex/hooks/post-tool-bash-telemetry.sh` | 431.5 | 455.7 | 687.5 |
| `bundle/.codex/hooks/post-tool-native-result-compact.sh` | 27.0 | 27.6 | 1319.1 |
| `bundle/.opencode/plugins/ralph-runtime-hooks.ts` | n/a (OpenCode plugin) | n/a | n/a |

## Compactor family registry (`_CORE_FAMILY_REGISTRY`, `bundle/.ralph/python/shell-output-compact.py`)

Every family below is registered with `safety_metadata={"safe": True, ...}` and
participates in classification by default (no per-family env var disables a
single family). `FAMILY_GENERIC_LARGE` and `FAMILY_FAILURE_AWARE` use
`_classifier_never` because they are invoked directly as fallback paths
(size-triggered fallback, and failure-output trimming) rather than selected
through the normal command-based classifier chain.

| Family | Classifier | On by default |
|--------|------------|----------------|
| `bats` | pattern classifier for `bats` invocations | Yes |
| `git_status` | `CLASSIFIER_GIT_STATUS` (dedicated classifier) | Yes |
| `git_log` | source-output family; never compacted | No (never) |
| `find` | source-output family; never compacted | No (never) |
| `npm_test` | pattern classifier for `npm test` | Yes |
| `vitest` | pattern classifier for `vitest` | Yes |
| `tsc` | `CLASSIFIER_TSC` (dedicated classifier) | Yes |
| `eslint` | pattern classifier for `eslint` | Yes |
| `pytest` | `CLASSIFIER_PYTEST` (dedicated classifier) | Yes |
| `shellcheck` | pattern classifier for `shellcheck` | Yes |
| `cargo_test` | dedicated classifier (`_classifier_cargo_test`) | Yes |
| `go_test` | dedicated classifier (`_classifier_go_test`) | Yes |
| `npm_install` | dedicated classifier (`_classifier_npm_install`) | Yes |
| `yarn_install` | dedicated classifier (`_classifier_yarn_install`) | Yes |
| `pip_install` | dedicated classifier (`_classifier_pip_install`) | Yes |
| `cargo_build` | dedicated classifier (`_classifier_cargo_build`) | Yes |
| `maven_build` | dedicated classifier (`_classifier_maven_build`) | Yes |
| `gradle_build` | dedicated classifier (`_classifier_gradle_build`) | Yes |
| `ls` | source-output family; never compacted | No (never) |
| `tree` | source-output family; never compacted | No (never) |
| `docker_ps` | pattern classifier for `docker ps` | Yes |
| `docker_logs` | pattern classifier for `docker logs` | Yes |
| `kubectl` | pattern classifier for `kubectl` | Yes |
| `gh_pr_view` | pattern classifier for `gh pr view` | Yes |
| `gh_pr_list` | pattern classifier for `gh pr list` | Yes |

The source-output denylist covers the following command families, including
families handled outside the normal registry:

| Source family | Shell compaction behavior |
|---------------|---------------------------|
| `git diff` | Never compacted |
| `git show` | Never compacted |
| `git log` | Never compacted |
| `grep`/`rg` | Never compacted |
| `find`, `ls`, `tree` | Never compacted |

These source-bearing families are never compacted by the normal classifier,
generic fallback, or failure fallback.
| `generic_large` | `_classifier_never` (invoked as a size-triggered fallback, gated by `RALPH_COMPACT_GENERIC_FALLBACK`, not selected by command classification) | Only when `RALPH_COMPACT_GENERIC_FALLBACK=1` (default off) |
| `failure_aware` | `_classifier_never` (invoked directly on non-zero-exit output, independent of the generic-fallback gate) | Yes (always applied to failure output regardless of `RALPH_COMPACT_GENERIC_FALLBACK`) |

### Success-versus-failure asymmetry

For the test-and-build families (`bats`, `pytest`, `npm_test`, `vitest`,
`tsc`, `eslint`, `shellcheck`, `cargo_test`, `go_test`, `cargo_build`,
`maven_build`, `gradle_build`), compaction is deliberately asymmetric:

- **Successful runs (`exit_status == 0`)** are summarized aggressively --
  passing-test noise, dependency/progress chatter, and per-file detail are
  collapsed down to a one- or few-line summary (counts of passed tests,
  "compilation successful", "no errors", etc.). There is no guarantee that
  any individual passing-test line survives compaction.
- **Failing runs (`exit_status != 0`)** preserve every error, assertion, and
  summary line. Each family compactor extracts every distinct failing test
  identifier, error code, or assertion message it recognizes (for example
  every `FAILED <nodeid>` line for `pytest`, every `not ok <n> <name>` block
  for `bats`, every `error TS<code>` line for `tsc`) and never truncates that
  list -- large failure counts are not capped or summarized away. The
  trailing summary line (`BUILD FAILURE`, `BUILD FAILED`, `N failed`, etc.)
  is always appended alongside the preserved failures.
  `tests/python/test_failure_output_preserved.py` asserts this invariant
  with realistic pytest, bats, and tsc failure fixtures, including fixtures
  large enough to have tripped the old truncation caps.
- The generic `failure_aware` fallback (used when no family compactor
  matches, or when a family compactor declines) applies the same rule at a
  coarser grain: it computes the set of error/assertion/summary lines via
  `_collect_preserve_lines` before trimming and refuses to return compacted
  output if any of those lines would be dropped, falling back to
  `_not_compacted` instead.

## Command-rewrite rules (`bundle/.ralph/python/shell_command_registry.py`)

The registry (`SHELL_COMMAND_RULES`) holds two kinds of rules. Match-only
rules exist solely to classify a command into a family for the compaction
layer and never alter the command text (for example `git_status`, which the
compactor still trims but whose command text is left untouched). Rewrite
rules carry an actual `rewrite=` function that changes the command text
before it runs. Exactly two rewrite rules exist, and both only fire when the
user passed no flags of their own that would conflict with the rewrite:

| Rule ID | Matches | Rewrite |
|---------|---------|---------|
| `tsc` | `tsc` invocations with no existing `--pretty` flag | Rewrites to `tsc --pretty false <rest>` so compiler diagnostics are not ANSI/box-drawing formatted. |
| `pytest` | `pytest` invocations with no existing quiet or `--tb` flag | Rewrites to `pytest -q --tb=line <rest>` for compact, single-line-per-failure output. |

`tests/python/test_shell_command_registry.py` asserts the number of rules
carrying a non-`None` `rewrite` callable stays at exactly two, so adding or
removing a rewrite rule must also update this table.

The whole rewrite path is gated behind `RALPH_BASH_REWRITE`, which is unset
by default, so no rewriting happens unless it is explicitly enabled (see
`RALPH_BASH_REWRITE` in the env var precedence chains below). Both rules
refuse to rewrite (return `None`, leaving the command unchanged) if the user
already passed a conflicting flag. `command-rewriter.sh` calls this registry
only when the caller (a hook or the MCP shell path) opts in; the registry
itself performs no I/O and does not execute commands.

## Env var precedence chains

- **`RALPH_NATIVE_RESULT_COMPACT`** (Read/Grep/Glob/SemanticSearch compaction
  on Claude, Cursor, Codex, and OpenCode): `0/false/no/off` explicitly
  disables; `1/true/yes/on` explicitly enables. If unset, Claude and Cursor's
  post-tool-native-result-compact hooks check
  `RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT` next (same truthy/falsy values),
  then default to **disabled** -- a truthy `RALPH_BASH_COMPACT` does **not**
  enable this path, because exploration-result compaction and Bash-output
  compaction have different safety contracts. OpenCode's plugin instead falls
  back to `RALPH_BASH_COMPACT` OR `RALPH_PROXY_SHELL_COMPACT` when
  `RALPH_NATIVE_RESULT_COMPACT` is unset.
- **`RALPH_BASH_COMPACT`** (Claude/OpenCode Bash stdout/stderr compaction):
  no fallback chain; `0` disables, anything else enables. Under Ralph plan
  runs, native|hybrid sets `RALPH_BASH_COMPACT=1` when unset via
  `run-plan-args.sh`. Cursor and Codex do not honor this variable for output
  replacement (their shell hooks use the wrapper/rewrite path instead; see
  `RALPH_BASH_REWRITE` below), only for their PostToolUse telemetry-skip
  records.
- **`RALPH_PROXY_SHELL_COMPACT`** (Ralph MCP proxy shell/result compaction,
  and the fallback source for Cursor's `post-tool-mcp-compact.sh` and
  OpenCode's native-result fallback): `RALPH_CURSOR_MCP_HOOK_COMPACT` takes
  precedence when explicitly set (`0/false/no/off` disables,
  `1/true/yes/on` enables); otherwise Cursor falls back to
  `RALPH_PROXY_SHELL_COMPACT` truthiness. Default is off.
- **`RALPH_COMPACT_GENERIC_FALLBACK`** (size-triggered generic compaction for
  commands with no matching family in `shell-output-compact.py`): read as a
  plain boolean (`1/true/yes/on` enables), default `"0"` (off). Independent of
  every other gate above; it only affects the `generic_large` family's
  fallback trigger, not `failure_aware`, which always runs on failed output.
- **`RALPH_BASH_REWRITE`** (pre-execution command rewriting on Claude, Cursor,
  Codex, and OpenCode): default off. On Cursor and Codex it is the fallback
  path when `RALPH_NATIVE_SHELL_WRAPPER` is not truthy (wrapper-based
  compaction takes precedence when both are set); on Claude and OpenCode it is
  the only rewrite path (there is no wrapper alternative on those runtimes).
  Independent of the killswitch check, which runs on every Bash/Shell call
  regardless of `RALPH_BASH_REWRITE` and is gated only by `RALPH_MODE`.

## Long-running commands

Only Claude Code exposes a native, model-callable background shell primitive
in the runtimes Ralph supports. The other runtimes rely on Ralph's own
background helpers.

| Runtime | Native shell tool | Background primitive | Notes |
|---|---|---|---|
| Claude | `Bash` | `run_in_background: true` plus the `BashOutput` tool | Returns a shell ID immediately; completion notification and output retrieval are via `BashOutput`. The normal `PostToolUse:Bash` compaction hooks still apply when the result is delivered. |
| Cursor | `Shell` | None | Cursor's native `Shell` tool does not support a background mode. Use `ralph_proxy_shell_start`/`_wait` for manual monitoring, or opt into `RALPH_BG_JOBS=1` with `.ralph/ralph-bg.sh` and the `stop` hook. |
| Codex | `Bash` / `command_execution` | None | Codex surfaces shell calls as either `Bash` or `command_execution`; neither has a proven background mode in the headless overlay. Use the same Ralph fallbacks as Cursor. |
| OpenCode | `bash` | None | The staged `ralph-runtime-hooks` plugin handles `bash` pre/post execution but does not implement a background shell mode. Use the Ralph fallbacks. |
| Antigravity | `Shell` | None | Antigravity's native `Shell` tool does not expose a background mode. Use the Ralph fallbacks. |

When a runtime has no native background shell support, the preferred pattern is:

1. Run the command through Ralph's own background path (`RALPH_BG_JOBS=1` plus `.ralph/ralph-bg.sh`) when the work should outlive the agent turn.
2. For a manually monitored job, use `ralph_proxy_shell_start` and then a blocking `ralph_proxy_shell_wait`.

Do not poll `ralph_proxy_shell_status` in a loop. Each poll re-sends the full context and wastes a turn. `ralph_proxy_shell_start`, `_status`, `_read`, `_wait`, and `_cancel` remain available as a fallback and are not deprecated.

## Duration capture by runtime

Learned durations feed `.ralph-workspace/command-profiles/profiles.json` so a
later PreToolUse path can inject native backgrounding where the runtime
supports it. Capture is honest about what each hook payload actually delivers:

| Runtime | Elapsed-time field in hook payload | Capture mechanism |
|---|---|---|
| Claude | **Yes** — top-level `.duration_ms` on `PostToolUse` (proven; see `tests/fixtures/native-hook/bash.json`) | Direct record in `compact-bash-output.sh` via `command_profiles.py record` |
| Cursor | **Yes** — top-level `.duration` (ms) on `afterShellExecution` (Cursor hooks docs); `postToolUse` also carries `.duration`, but Ralph records only from `afterShellExecution` to avoid double-counting the same Shell call | Direct record in `after-shell-telemetry.sh` |
| Antigravity | **Yes** — same Cursor-shaped `afterShellExecution` payload via `.agents/hooks/after-shell-telemetry.sh` | Same direct-record path as Cursor |
| Codex | **No** — observed `PostToolUse` keys are `cwd`, `hook_event_name`, `model`, `permission_mode`, `session_id`, `tool_input`, `tool_name`, `tool_response`, `tool_use_id`, `transcript_path`, `turn_id` (no `duration_ms`) | Pre/post pairing: `pre-tool-bash-policy.sh` writes a start marker under `.ralph-workspace/command-profiles/inflight/` keyed by `tool_use_id`; `post-tool-bash-telemetry.sh` computes the delta and records it |
| OpenCode | **No** — `tool.execute.after` input is `{ tool, sessionID, callID, args }` with mutable `{ title, output, metadata }`; no duration field in the plugin contract | Pre/post pairing in `ralph-runtime-hooks.ts`/`.mjs`: mark on `tool.execute.before`, complete on `tool.execute.after`, keyed by `callID` |

Inflight markers expire after one hour (`INFLIGHT_MAX_AGE_SECONDS`) so an
interrupted run cannot leak entries forever. Concurrent identical commands are
tolerated by keying on the runtime-supplied invocation id (`tool_use_id` /
`callID`).

## Learned command profiles and the never-background denylist

Ralph records shell durations under `.ralph-workspace/command-profiles/profiles.json`
so a later PreToolUse path can inject native backgrounding for known slow
commands. **Recording and backgrounding are separate decisions.**

- **Recording** always happens for fingerprintable commands (subject to lock/I/O
  silent drops). Durations stay useful even when auto-backgrounding would be
  unsafe, so operators can still inspect medians and promotion history.
- **Background injection** only runs when an entry is marked `long_running` and
  the command is **not** on the never-background denylist. Some commands are
  slow precisely because later steps depend on them finishing; backgrounding
  those breaks ordering in a way that is hard to diagnose.

Built-in denylist shapes (never auto-backgrounded, still recorded):

- Dependency installs: `npm`/`pnpm`/`yarn` install (and `npm`/`pnpm` `ci`),
  `pip`/`pip3` install, `cargo fetch`, `bundle install`, `go mod download`
- Mutating git: `clone`, `pull`, `fetch`, `push`, `merge`, `rebase`, `checkout`
- Database migrations and seeds
- Commands matching `deploy`, `publish`, or `release`
- Commands that already contain a shell background operator (`&`), or that were
  already invoked with `run_in_background`

Project-specific additions go in a plain newline-delimited file at
`.ralph-workspace/command-profiles/never-background` (one regex per line;
`#` comments and blank lines ignored). That data file is the extension point;
there is no environment variable for the denylist.

## Inspecting and correcting learned profiles (`ralph profiles`)

Learned entries are visible and correctable so a wrong promotion is never an
invisible trap. Use the public CLI:

```bash
ralph profiles list
ralph profiles show <fingerprint-prefix>
ralph profiles reset <fingerprint-prefix>
ralph profiles reset --yes          # clear the whole store (non-interactive)
```

- **`list`** prints learned commands sorted by median duration descending, with
  the redacted command, observation count, median in seconds, whether the entry
  is marked long-running, and whether it is denylisted.
- **`show <fingerprint-prefix>`** prints the full record for a unique prefix,
  including retained `durations_ms` and promotion/demotion timestamps.
- **`reset [<fingerprint-prefix>]`** clears one entry by unique prefix, or with
  no argument clears the whole store after an explicit confirmation prompt.
  A full-store reset refuses to run non-interactively without `--yes`, so an
  agent cannot wipe the store by accident.

Options `--workspace` / `--workspace-root` select the project and state roots
(same three-root model as other Ralph CLIs). See `ralph profiles --help`.
