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
| `bundle/.claude/hooks/compact-bash-output.sh` | Claude | `PostToolUse` | `Bash` | `RALPH_BASH_COMPACT` (on by default; Claude's shipped `settings.json` sets `RALPH_BASH_COMPACT=1` on the hook invocation itself) | Runs the shared shell-output compactor on successful Bash stdout/stderr, stores the original, and replaces `tool_response` via `hookSpecificOutput.updatedToolOutput`, appending a stored-result footer. | Exits 0 (leaves output untouched) on missing `jq`, wrong event/tool, malformed `tool_response`, missing compactor library, or `RALPH_BASH_COMPACT` falsy; only fires on successful (exit 0) Bash calls because Claude does not deliver `tool_response` on failures. |
| `bundle/.claude/hooks/rewrite-bash-command.sh` | Claude | `PreToolUse` | `Bash` | `RALPH_BASH_REWRITE` (default off) | Runs the shared command-rewriter registry against `tool_input.command` and, if a rule applies, replaces the command via `hookSpecificOutput.updatedInput` before execution; also evaluates the killswitch policy (gated separately by `RALPH_MODE`, not by `RALPH_BASH_REWRITE`) on every Bash call regardless of the rewrite gate. | Exits 0 (command runs unchanged) on missing `jq`/`python3`, wrong event/tool, empty command, missing rewriter library, no matching rule, or `RALPH_BASH_REWRITE` falsy. |
| `bundle/.claude/hooks/native-result-compact.sh` | Claude | `PostToolUse` | `Read\|Grep\|Glob` | `RALPH_NATIVE_RESULT_COMPACT` (default off; explicit opt-in) | Delegates to the shared `post-tool-native-result-compact-hook.sh`, which compacts Read/Grep/Glob output through the same envelope/store path as MCP proxy results and replaces the tool output. | Exits 0 (leaves output untouched) when the shared hook script is missing, when `RALPH_NATIVE_RESULT_COMPACT` is not explicitly truthy, or on any internal failure; `RALPH_BASH_COMPACT` truthiness does **not** enable this path (source-bearing Read/Grep/Glob output has a different safety contract than Bash stdout). |
| `bundle/.claude/hooks/block-env-reads.sh` | Claude | `PreToolUse` | `Read\|Edit\|MultiEdit\|Glob\|Grep\|LS` | none (always active; not gated by an env var) | Inspects `path`/`file_path`/`filename` in the tool input and blocks (exit 1, stderr message) any call whose basename starts with `.env`. | This hook fails open only on missing/unmatched input (no path found -> allow); when it does match a `.env*` basename it deliberately blocks (exit 1) rather than fails open, because blocking secret reads is the point of the hook. |
| `bundle/.claude/hooks/stop-continuation.sh` | Claude | `Stop` | n/a (Stop hooks are not tool-scoped) | none directly; the underlying core respects `RALPH_BG_JOBS` / background-job state | Waits for Ralph background jobs registered against the run and blocks the Stop event with a reason (forcing another turn) while jobs remain outstanding. | Exits 0 (lets Claude stop normally) on missing `jq`, unresolved project directory, or missing adapter/core scripts. |
| `bundle/.cursor/hooks/pre-tool-shell-policy.sh` | Cursor / Antigravity (`.agents/hooks`) | `preToolUse` | `Shell` | `RALPH_NATIVE_SHELL_WRAPPER` (default on when Ralph enables Cursor native hooks) with `RALPH_BASH_REWRITE` (default off) as the fallback path | Evaluates the killswitch, then either wraps the command through the shared native-shell-wrapper (captures/compacts output, stores originals) when `RALPH_NATIVE_SHELL_WRAPPER` is truthy, or applies a plain command-rewrite when only `RALPH_BASH_REWRITE` is truthy, and emits `updated_input.command`. | Exits 0 (command runs unchanged) on missing `jq`/`python3`, wrong event/tool, empty command, unresolved workspace, missing rewriter library, both gates off, or no rule match. |
| `bundle/.cursor/hooks/pre-tool-exploration-policy.sh` | Cursor / Antigravity | `preToolUse` | `Read\|read\|readToolCall\|Grep\|grep\|grepToolCall\|Glob\|glob\|globToolCall\|SemanticSearch\|semanticSearch` | `RALPH_NATIVE_EXPLORATION_NUDGE` (default derives from strict Ralph mode; `=1` forces on, `=0` opts out) | In strict `ralph` mode (native hooks off), denies native Read/Grep/Glob/SemanticSearch so the agent is nudged toward `ralph_proxy_*` MCP tools instead; native Read is allowed only for paths recently handed off by `pre-tool-proxy-read-handoff.sh`. | Exits 0 (allows the native call) when not in strict mode, when the nudge is explicitly disabled, or on any internal failure. |
| `bundle/.cursor/hooks/pre-tool-proxy-read-handoff.sh` | Cursor / Antigravity | `preToolUse` | `MCP:ralph_proxy_read` | `RALPH_NATIVE_EXPLORATION_NUDGE` (same gate as the exploration policy above) | Records the path just read via `ralph_proxy_read` so the immediately following native Read on that same path is allowed through `pre-tool-exploration-policy.sh` (supports the proxy-read -> native-Read -> Edit flow). | Exits 0 (records nothing, no effect on the next call) when the nudge gate is off or on any internal failure. |
| `bundle/.cursor/hooks/post-tool-shell-telemetry.sh` | Cursor / Antigravity | `postToolUse` | `Shell` | `RALPH_BASH_TELEMETRY_LOG` (unset by default; observability only) | Appends a JSONL audit line (byte counts, command hash) to the configured telemetry log; does **not** attempt output replacement because Cursor's `updated_tool_output` is proven not to change agent-visible Shell stdout. | Exits 0 always; missing `jq` or unset `RALPH_BASH_TELEMETRY_LOG` simply skips logging. |
| `bundle/.cursor/hooks/post-tool-native-result-compact.sh` | Cursor / Antigravity | `postToolUse` | `Read\|read\|readToolCall\|Grep\|grep\|grepToolCall\|Glob\|glob\|globToolCall\|SemanticSearch\|semanticSearch` | `RALPH_NATIVE_RESULT_COMPACT` (default off; explicit opt-in) | Delegates to the same shared `post-tool-native-result-compact-hook.sh` used by Claude/Codex to compact native exploration output and replace it via `updated_tool_output`. | Exits 0 (leaves output untouched) when the shared hook is missing, the gate is off, or on any internal failure. |
| `bundle/.cursor/hooks/pre-tool-proxy-read-handoff.sh` / `post-tool-mcp-compact.sh` | Cursor / Antigravity | `postToolUse` | `MCP:*` (scoped internally to `ralph_proxy_read\|ralph_proxy_grep\|ralph_proxy_glob\|ralph_proxy_shell`) | `RALPH_CURSOR_MCP_HOOK_COMPACT` (explicit override) falling back to `RALPH_PROXY_SHELL_COMPACT` (default off) | Compacts Ralph MCP proxy tool results that exceed the per-tool byte cap and replaces them via `updated_mcp_tool_output`, storing the original for later retrieval; records windowing telemetry when the shared telemetry lib is present. | Exits 0 (leaves the MCP result untouched) when disabled, the tool isn't a `ralph_proxy_*` tool, the result is already an envelope, the result is under the byte cap, or any library fails to load. |
| `bundle/.cursor/hooks/after-shell-telemetry.sh` | Cursor / Antigravity | `afterShellExecution` | n/a (fires for every shell execution) | `RALPH_BASH_TELEMETRY_LOG` (unset by default; observability only) | Appends a one-line audit record (timestamp, byte count, command hash) to the configured telemetry log after a shell command finishes. | Exits 0 always; missing `jq` or unset `RALPH_BASH_TELEMETRY_LOG` simply skips logging. |
| `bundle/.cursor/hooks/stop-continuation.sh` | Cursor / Antigravity | `stop` | n/a | none directly; underlying core respects background-job state | Same background-job wait/block behavior as the Claude Stop hook, adapted for Cursor's `stop` hook shape (`loop_limit: 5` in `hooks.json`). | Exits 0 (lets the run stop normally) on missing dependencies or unresolved project directory. |
| `bundle/.codex/hooks/pre-tool-bash-policy.sh` | Codex | `PreToolUse` | `Bash` / `command_execution` | `RALPH_NATIVE_SHELL_WRAPPER` (default on when Ralph enables Codex native hooks) with `RALPH_BASH_REWRITE` (default off) as the fallback path | Evaluates the killswitch, then wraps the command through the native-shell-wrapper when `RALPH_NATIVE_SHELL_WRAPPER` is truthy, or falls back to a plain command-rewrite when only `RALPH_BASH_REWRITE` is truthy, emitting `hookSpecificOutput.updatedInput.command`. | Exits 0 (command runs unchanged) on missing `jq`/`python3`, wrong event/tool, empty command, unresolved workspace, or no rewrite/wrapper produced. |
| `bundle/.codex/hooks/post-tool-bash-telemetry.sh` | Codex | `PostToolUse` | `Bash` / `command_execution` | `RALPH_BASH_TELEMETRY_LOG` (unset by default; observability only) | Appends a JSONL audit line (byte counts, command hash, `compactionSkipped: true`) because Codex's model-visible PostToolUse output mutation is unproven on the current CLI build; this hook never rewrites output. | Exits 0 always; missing `jq`, wrong event/tool, or unset `RALPH_BASH_TELEMETRY_LOG` skips logging. |
| `bundle/.codex/hooks/post-tool-native-result-compact.sh` | Codex | `PostToolUse` | `read_file\|grep\|Glob\|Read\|Grep` | `RALPH_NATIVE_RESULT_COMPACT` (default off; explicit opt-in) | Delegates to the same shared `post-tool-native-result-compact-hook.sh` used by Claude/Cursor to compact native read/grep/glob output. | Exits 0 (leaves output untouched) when the shared hook is missing, the gate is off, or on any internal failure. |
| `bundle/.opencode/plugins/ralph-runtime-hooks.ts` / `.mjs` | OpenCode | `tool.execute.before`, `tool.execute.after` (OpenCode plugin lifecycle hooks, not settings-file hooks) | `bash` (rewrite + compaction); `read\|grep\|glob\|search\|bash` (exploration result compaction) | `RALPH_BASH_REWRITE` (default off) for the pre-tool rewrite; `RALPH_NATIVE_RESULT_COMPACT` / `RALPH_BASH_COMPACT` / `RALPH_PROXY_SHELL_COMPACT` (see precedence below) for post-tool compaction; `RALPH_BASH_TELEMETRY_LOG` (unset by default) for telemetry | Before execution, rewrites `bash` commands via the shared Python rewriter when `RALPH_BASH_REWRITE` is truthy; after execution, compacts `bash` output via the shared native-result compactor when enabled (else via `shell-output-compact.py` when only `RALPH_BASH_COMPACT` is truthy), compacts other exploration-tool output via the native-result compactor when enabled, and always appends telemetry when `RALPH_BASH_TELEMETRY_LOG` is set. Headless model-visible mutation via this plugin path is unproven on the current OpenCode build (see `SPIKE-output-mutation.md`); MCP proxy compaction remains the reliable path. | On any spawn failure, non-zero exit from the Python/bash helper, or JSON parse failure, the plugin returns the original command/output unchanged (no exception propagates to the tool call); the `.ts` file is the typed source and the `.mjs` file is the plain-JS twin actually loaded at runtime, kept behaviorally identical. |

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
| `git_log` | pattern classifier for `git log` | Yes |
| `find` | pattern classifier for `find` | Yes |
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
| `ls` | pattern classifier for `ls` | Yes |
| `tree` | pattern classifier for `tree` | Yes |
| `docker_ps` | pattern classifier for `docker ps` | Yes |
| `docker_logs` | pattern classifier for `docker logs` | Yes |
| `kubectl` | pattern classifier for `kubectl` | Yes |
| `gh_pr_view` | pattern classifier for `gh pr view` | Yes |
| `gh_pr_list` | pattern classifier for `gh pr list` | Yes |
| `generic_large` | `_classifier_never` (invoked as a size-triggered fallback, gated by `RALPH_COMPACT_GENERIC_FALLBACK`, not selected by command classification) | Only when `RALPH_COMPACT_GENERIC_FALLBACK=1` (default off) |
| `failure_aware` | `_classifier_never` (invoked directly on non-zero-exit output, independent of the generic-fallback gate) | Yes (always applied to failure output regardless of `RALPH_COMPACT_GENERIC_FALLBACK`) |

## Command-rewrite rules (`bundle/.ralph/python/shell_command_registry.py`)

The rewrite registry (`SHELL_COMMAND_RULES`) defines many command-family
matchers used for compaction classification, but only three carry an actual
`rewrite=` function that changes the command text before it runs:

| Rule ID | Matches | Rewrite |
|---------|---------|---------|
| `git_status` | `git status` with no existing porcelain/short/branch flags | Rewrites to `git status --porcelain=v2 --branch <rest>` for deterministic, machine-parseable output. |
| `tsc` | `tsc` invocations with no existing `--pretty` flag | Rewrites to `tsc --pretty false <rest>` so compiler diagnostics are not ANSI/box-drawing formatted. |
| `pytest` | `pytest` invocations with no existing quiet or `--tb` flag | Rewrites to `pytest -q --tb=line <rest>` for compact, single-line-per-failure output. |

All three refuse to rewrite (return `None`, leaving the command unchanged) if
the user already passed a conflicting flag. `command-rewriter.sh` calls this
registry only when the caller (a hook or the MCP shell path) opts in; the
registry itself performs no I/O and does not execute commands.

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
  no fallback chain; `0` disables, anything else (including Claude's shipped
  `settings.json` value of `1`) enables. Cursor and Codex do not honor this
  variable for output replacement (their shell hooks use the wrapper/rewrite
  path instead; see `RALPH_BASH_REWRITE` below), only for their PostToolUse
  telemetry-skip records.
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
