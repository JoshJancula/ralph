#!/usr/bin/env bash
#
# Permission-remediation classifier for runner invocations.
#
# Classifies permission-related failures separately from generic errors and
# rate limits.  The main entry point is ralph_classify_permission_block which
# returns a classification string via stdout so callers can decide whether and
# how to handle remediation.
#
# Public interface:
#   ralph_classify_permission_block <output_segment> <exit_code> <runtime>
#     Prints classification tag to stdout on success (returns 0).
#     Returns 1 when the invocation does NOT look like a permission block
#     (i.e. it is a generic error, success, or rate-limit case).
#
#   ralph_classify_permission_block_fallback <output_segment> <exit_code> <runtime>
#     Second pass when the primary classifier returns no match. Uses weaker
#     permission-like signals (no runtime vendor signature required) and
#     always prints permission_unknown when it matches.
#
#   ralph_permission_block_type <output_segment> <exit_code> <runtime>
#     Convenience wrapper that always returns 0 and prints either the
#     classification tag or "none" when no permission block is detected.
#
#   ralph_permission_hint <block_type> <runtime> [blocked_shell_cmd] [denial_excerpt]
#     Operator-facing remediation text. Optional denial_excerpt is the
#     invocation output segment used for Claude-specific sub-detection and
#     Codex-specific triage (writable-path vs sandbox preset vs host rule).
#
# Supported classifications:
#   allowlist_command    -- Command blocked by an allowlist policy
#   sandbox_path         -- Path access denied inside a sandbox
#   external_directory   -- External/writable directory access rejected
#   restricted_tool      -- Tool invocation blocked by permission rules
#   network_or_host_restriction -- Network/host access denied
#   approval_rejected   -- User-side approval prompt was rejected
#   permission_unknown   -- Permission block detected but cannot be sub-classified
#
# The function intentionally leans toward false negatives over false positives:
# ambiguous output is treated as a generic error (returns 1) rather than
# misclassified as a permission block.

# Canonical list of known classification tags (one per line for easy grep).
RALPH_PERMISSION_BLOCK_TYPES="allowlist_command
sandbox_path
external_directory
restricted_tool
network_or_host_restriction
approval_rejected
permission_unknown"

ralph_permission_block_is_host_registry_noise() {
  local text="${1:-}"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  # Codex can inherit parent-session transport markers and then fail before a
  # model turn while initializing its in-process app-server client.  Although
  # the platform error can contain "Operation not permitted", it is a runtime
  # bootstrap error, not an approval request an operator can resolve.
  if printf '%s\n' "$lower" | grep -qF 'failed to initialize in-process app-server client'; then
    return 1
  fi

  if printf '%s\n' "$lower" | grep -qE 'workspace-registry:|skipping ralph workspace registry|failed to update ralph workspace registry'; then
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'traceback \(most recent call last\).*(workspace-registry|workspaces\.json)'; then
    return 0
  fi
  return 1
}

ralph_permission_is_runtime_bootstrap_failure() {
  local text="${1:-}"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$lower" | grep -qF 'failed to initialize in-process app-server client'
}

# ralph_permission_is_termination <output_segment> <exit_code>
# Termination branch for the permission classifier (G10/G11). Runner-owned
# timeout / cancel / signal exits outrank permission-shaped transcript
# wording. Returns 0 when this invocation is a termination, not a
# permission block -- callers must not fabricate a permission pause.
#
# Recognized termination signals:
#   - exit 124 (timeout(1)-style), 130 (SIGINT), 143 (SIGTERM), 78 (abort)
#   - run-plan-owned timeout marker lines in the output segment
#   - explicit cancel / received-signal notices that are not approval prompts
ralph_permission_is_termination() {
  local text="${1:-}"
  local exit_code="${2:-0}"
  local lower

  case "$exit_code" in
    78 | 124 | 130 | 143) return 0 ;;
  esac

  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$lower" ]] || return 1

  if printf '%s\n' "$lower" | grep -qE 'invocation (stuck: timeout|timeout exceeded|terminated due to timeout)|terminated due to timeout \(elapsed'; then
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'received signal (term|int|hup|kill)|operator cancel(led)?|cancelled by (the )?(operator|supervisor)|supervisor (cancel|signal|interrupt)'; then
    return 0
  fi
  return 1
}

ralph_classify_permission_block() {
  local text="${1:-}"
  local exit_code="${2:-0}"
  local runtime="${3:-}"

  if ralph_permission_block_is_host_registry_noise "$text"; then
    return 1
  fi

  # Termination branch: never treat runner timeout / cancel / signal exits
  # as permission blocks, even when the transcript mentions "permission
  # denied" or similar diagnostic wording.
  if ralph_permission_is_termination "$text" "$exit_code"; then
    return 1
  fi

  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  # Some runtimes surface permission denials as explicit output while still
  # exiting 0. Only continue classifying zero-exit output when the text itself
  # contains a denial signal.
  if [[ "$exit_code" -eq 0 ]] && ! printf '%s\n' "$lower" | grep -qE 'permission[[:space:]]+requested|auto[-[:space:]]*reject|external([[:space:]_-]+)?directory|permission.*(rejected|denied|declined)|approval.*(rejected|denied|declined)|explicit.*(user )?(reject|denied|declined)'; then
    return 1
  fi

  # ---- Cursor-specific patterns ----
  # "Not in allowlist", "Add Shell(...) to allowlist", "Run this command?"
  if printf '%s\n' "$lower" | grep -qE 'not in (the )?allowlist'; then
    printf 'allowlist_command\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'add .+ to (the )?allowlist'; then
    printf 'allowlist_command\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'run this command\?'; then
    printf 'approval_rejected\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'auto.run.everything'; then
    printf 'approval_rejected\n'
    return 0
  fi

  # ---- Claude-specific patterns ----
  # Missing write/edit tool, permission mode restriction, tool approval
  if printf '%s\n' "$lower" | grep -qE '(permission|policy).*mode.*(restrict|deny|block|disallow|forbidden)'; then
    printf 'restricted_tool\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'tool.*(not allowed|disallowed|blocked|denied|not permitted|not authorized)'; then
    printf 'restricted_tool\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(write|edit|create).*file.*(not allowed|denied|permission)'; then
    printf 'restricted_tool\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'was not (auto-)?approved'; then
    printf 'approval_rejected\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'allowedtools|allowed tools.*(omit|missing|not include|exclude)'; then
    printf 'restricted_tool\n'
    return 0
  fi

  # ---- Codex-specific patterns ----
  # Sandbox path restrictions, external directory, host-side escalation
  if printf '%s\n' "$lower" | grep -qE '(sandbox|container).*path.*(denied|not (allowed|permitted|accessible)|restricted|forbidden|block)'; then
    printf 'sandbox_path\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'path.*(not allowed|not accessible|denied|forbidden).*sandbox'; then
    printf 'sandbox_path\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'external([[:space:]_-]+)?(directory|folder|path)'; then
    printf 'external_directory\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(outside|beyond).*sandbox.*(write|writable|access)'; then
    printf 'external_directory\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'user.*(reject|denied|declined).*approval'; then
    printf 'approval_rejected\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(explicit|explicitly).*(user )?(reject|denied|declined)'; then
    printf 'approval_rejected\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'approval.*(reject|denied|declined)'; then
    printf 'approval_rejected\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'host.*(wrapper|side).*(permission|denied|escalat)'; then
    printf 'permission_unknown\n'
    return 0
  fi

  # ---- OpenCode-specific patterns (require OpenCode signal in text) ----
  if printf '%s\n' "$lower" | grep -qF 'opencode'; then
    if printf '%s\n' "$lower" | grep -qE 'opencode.*(external[_[:space:]-]directory|external directory).*(denied|blocked|reject|not allowed)'; then
      printf 'external_directory\n'
      return 0
    fi
    if printf '%s\n' "$lower" | grep -qE 'opencode.*(user|operator).*(reject|declined|denied|canceled|cancelled|dismiss)'; then
      printf 'approval_rejected\n'
      return 0
    fi
    if printf '%s\n' "$lower" | grep -qE 'opencode.*(permission|approval|tool request).*(reject|declined|denied|canceled|cancelled)'; then
      printf 'approval_rejected\n'
      return 0
    fi
    if printf '%s\n' "$lower" | grep -qE '(reject|declined|denied).*(permission|approval).*opencode'; then
      printf 'approval_rejected\n'
      return 0
    fi
    if printf '%s\n' "$lower" | grep -qE 'opencode.*(sandbox|filesystem|path).*(denied|blocked|not permitted|read-only|forbidden|eacces|not allowed)'; then
      printf 'sandbox_path\n'
      return 0
    fi
    if printf '%s\n' "$lower" | grep -qE 'opencode.*(sandbox|permission|not allowed)'; then
      printf 'permission_unknown\n'
      return 0
    fi
  fi
  if printf '%s\n' "$lower" | grep -qE 'tool.*(not available|not enabled|disabled|restricted).*opencode'; then
    printf 'restricted_tool\n'
    return 0
  fi

  # ---- Cross-runtime patterns ----
  # Network / host access restrictions
  if printf '%s\n' "$lower" | grep -qE '(network|internet|dns|fetch|connect).*(denied|blocked|restricted|not allowed|forbidden|refused)'; then
    printf 'network_or_host_restriction\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(host|hostname|domain|endpoint).*(denied|blocked|restricted|not allowed|forbidden|unreachable)'; then
    printf 'network_or_host_restriction\n'
    return 0
  fi

  # Generic sandbox/path patterns (no specific runtime signal)
  if printf '%s\n' "$lower" | grep -qE '(read|write|execute|access).*(denied|not permitted|forbidden)'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'operation not permitted'; then
    printf 'permission_unknown\n'
    return 0
  fi

  return 1
}

# Weak-signal fallback when primary patterns miss (e.g. no runtime vendor signature).
ralph_classify_permission_block_fallback() {
  local text="${1:-}"
  local exit_code="${2:-0}"
  local runtime="${3:-}"

  if ralph_permission_block_is_host_registry_noise "$text"; then
    return 1
  fi

  # Same termination short-circuit as the primary classifier: runner-owned
  # markers and signal exits outrank weak permission-like wording.
  if ralph_permission_is_termination "$text" "$exit_code"; then
    return 1
  fi

  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  if [[ "$exit_code" -eq 0 ]] && ! printf '%s\n' "$lower" | grep -qE 'permission[[:space:]]+requested|auto[-[:space:]]*reject|external([[:space:]_-]+)?directory|permission.*(rejected|denied|declined)|approval.*(rejected|denied|declined)|explicit.*(user )?(reject|denied|declined)'; then
    return 1
  fi

  if printf '%s\n' "$lower" | grep -qE 'rate[[:space:]]+limit|five_hour|out of credits'; then
    return 1
  fi
  if printf '%s\n' "$lower" | grep -qE 'syntaxerror|referenceerror|typeerror:|panic:|segfault|traceback \(most recent'; then
    return 1
  fi

  if printf '%s\n' "$lower" | grep -qE '(permission|policy|guard|allowlist|sandbox|approval).*(denied|blocked|refused|rejected|not allowed|forbidden|disallowed)'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(denied|blocked|refused|rejected|disallowed|forbidden).*(permission|policy|sandbox|approval|allowlist|guard)'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'permission[[:space:]]+not[[:space:]]+allowed'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(requires?|needs?)[[:space:]]+(additional[[:space:]]+)?(approval|permission|elevated|privilege)'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'insufficient[[:space:]]+privileg'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'security[[:space:]]+policy[[:space:]]+blocked'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(tool|command|action|capability)[[:space:]]+(blocked|refused|denied)'; then
    printf 'permission_unknown\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(blocked|refused|denied)[[:space:]]+(by|due to)[[:space:]]+(policy|guard|rules?)'; then
    printf 'permission_unknown\n'
    return 0
  fi

  return 1
}

ralph_cursor_blocked_command() {
  local text="${1:-}"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  local cmd=""
  if printf '%s\n' "$lower" | grep -qE 'not in (the )?allowlist'; then
    cmd="$(printf '%s' "$text" | sed -n 's/.*Shell(\([^)]*\)).*/\1/p' | head -1)"
  fi
  if [[ -z "$cmd" ]] && printf '%s\n' "$lower" | grep -qE 'add .+ to (the )?allowlist'; then
    cmd="$(printf '%s' "$text" | sed -n 's/.*Shell(\([^)]*\)).*/\1/p' | head -1)"
  fi
  if [[ -z "$cmd" ]] && printf '%s\n' "$lower" | grep -qE 'run this command\?'; then
    cmd="$(printf '%s' "$text" | sed -n 's/.*Shell(\([^)]*\)).*/\1/p' | head -1)"
    if [[ -z "$cmd" ]]; then
      cmd="$(printf '%s' "$text" | sed -n 's/.*: \([^)]*\)$/\1/p' | head -1)"
    fi
  fi
  printf '%s\n' "$cmd"
}

# Best-effort path extraction from denial text (Codex/OpenCode sandbox and external paths).
ralph_permission_blocked_path() {
  local text="${1:-}"
  local p=""
  p="$(printf '%s' "$text" | sed -E -n 's/.*[Pp]ermission[[:space:]]+[Rr]equested:[[:space:]]*(external[_[:space:]-]directory|external[[:space:]]+directory)[[:space:]]*\(([^)]*)\).*/\2/p' | head -1)"
  if [[ -z "$p" ]]; then
    p="$(printf '%s' "$text" | sed -E -n 's/.*[Pp]ermission[[:space:]]+[Rr]equested:[[:space:]]*[^[:space:]]+[[:space:]]*\(([^)]*)\).*/\1/p' | head -1)"
  fi
  if [[ -z "$p" ]]; then
    p="$(printf '%s' "$text" | sed -E -n 's/.*[Ss]andbox[[:space:]]+[Pp]ath[[:space:]]+[Dd]enied[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
  fi
  if [[ -z "$p" ]]; then
    p="$(printf '%s' "$text" | sed -E -n 's/.*[Ee]xternal[[:space:]]+[Dd]irectory[^:]*:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
  fi
  if [[ -z "$p" ]]; then
    p="$(printf '%s' "$text" | sed -E -n 's/.*[Oo]pen[Cc]ode[^:]*[Pp]ath[[:space:]]+([^[:space:]]+)[[:space:]]+is not allowed.*/\1/p' | head -1)"
  fi
  if [[ -z "$p" ]]; then
    p="$(printf '%s' "$text" | sed -E -n 's/.*[Rr]ead not permitted on[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)"
  fi
  if [[ -z "$p" ]]; then
    p="$(printf '%s' "$text" | sed -E -n 's/^[[:space:]]*[Pp]ath[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
  fi
  printf '%s\n' "$p"
}

# Best-effort command from generic denial text (Command: ..., Shell(...), etc.).
ralph_permission_blocked_command_generic() {
  local text="${1:-}"
  local cmd=""
  cmd="$(printf '%s' "$text" | sed -n 's/.*Shell(\([^)]*\)).*/\1/p' | head -1)"
  if [[ -z "$cmd" ]]; then
    cmd="$(printf '%s' "$text" | sed -E -n 's/.*[Cc]ommand[[:space:]]*:[[:space:]]*([^[:cntrl:]]+).*/\1/p' | head -1)"
  fi
  if [[ -z "$cmd" ]]; then
    cmd="$(printf '%s' "$text" | sed -E -n 's/.*[Bb]locked[[:space:]]+(command|tool)[[:space:]]*:[[:space:]]*([^[:cntrl:]]+).*/\2/p' | head -1)"
  fi
  printf '%s\n' "$cmd"
}

# Best-effort tool name from Claude-style denial text.
ralph_permission_blocked_tool() {
  local text="${1:-}"
  local lower t=""
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  t="$(printf '%s' "$lower" | sed -E -n 's/.*tool[[:space:]]+([a-z][a-z0-9_-]*)[[:space:]]+(is not|blocked|disallowed|not permitted|not allowed).*/\1/p' | head -1)"
  if [[ -z "$t" ]]; then
    t="$(printf '%s' "$lower" | sed -E -n 's/.*(write|edit|bash|read)[[:space:]]+tool.*/\1/p' | head -1)"
  fi
  printf '%s\n' "$t"
}

# Build a copy-paste resume shell command mirroring the current run-plan invocation context.
ralph_build_permission_resume_command() {
  local workspace="${1:?}"
  local plan_abs="${2:?}"
  local runtime="${3:?}"
  local script="${SCRIPT_PATH:-}"
  if [[ -z "$script" || ! -f "$script" ]]; then
    script="${SCRIPT_DIR:-.}/run-plan.sh"
  fi

  local plan_rel="$plan_abs"
  if [[ -n "$workspace" && "$plan_abs" == "$workspace"/* ]]; then
    plan_rel="${plan_abs#"${workspace}"/}"
  fi

  local parts=""
  parts+="cd $(printf %q "$workspace") && "
  if [[ -n "${RALPH_USAGE_RISKS_ACKNOWLEDGED:-}" ]]; then
    parts+="RALPH_USAGE_RISKS_ACKNOWLEDGED=$(printf %q "$RALPH_USAGE_RISKS_ACKNOWLEDGED") "
  fi
  if [[ -n "${RALPH_PLAN_SESSION_HOME:-}" ]]; then
    parts+="RALPH_PLAN_SESSION_HOME=$(printf %q "$RALPH_PLAN_SESSION_HOME") "
  fi
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    parts+="RALPH_PLAN_KEY=$(printf %q "$RALPH_PLAN_KEY") "
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" && "${RALPH_ARTIFACT_NS}" != "${RALPH_PLAN_KEY:-}" ]]; then
    parts+="RALPH_ARTIFACT_NS=$(printf %q "$RALPH_ARTIFACT_NS") "
  fi
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    parts+="RALPH_PLAN_WORKSPACE_ROOT=$(printf %q "$RALPH_PLAN_WORKSPACE_ROOT") "
  fi
  parts+="bash $(printf %q "$script") "
  parts+="--runtime $(printf %q "$runtime") "
  parts+="--plan $(printf %q "$plan_rel") "
  parts+="--workspace $(printf %q "$workspace") "
  if [[ "${NON_INTERACTIVE_FLAG:-0}" == "1" ]]; then
    parts+="--non-interactive "
  fi
  if [[ -n "${SELECTED_MODEL:-}" ]]; then
    parts+="--model $(printf %q "$SELECTED_MODEL") "
  fi
  local strat="${RALPH_PLAN_SESSION_STRATEGY:-fresh}"
  if [[ "$strat" != "fresh" ]]; then
    parts+="--session-strategy $(printf %q "$strat") "
  fi
  # Mirror run-plan-args: resume/reset enable CLI resume; fresh and checkpoint do not.
  case "$strat" in
    resume|reset) parts+="--cli-resume " ;;
  esac
  if [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    parts+="--allow-unsafe-resume "
  fi
  if [[ -n "${CLAUDE_PLAN_PERMISSION_MODE:-}" ]]; then
    parts+="CLAUDE_PLAN_PERMISSION_MODE=$(printf %q "$CLAUDE_PLAN_PERMISSION_MODE") "
  fi
  if [[ -n "${RALPH_PLAN_VERIFICATION_MODE:-}" ]]; then
    parts+="RALPH_PLAN_VERIFICATION_MODE=$(printf %q "$RALPH_PLAN_VERIFICATION_MODE") "
  fi
  printf '%s' "$parts" | sed 's/[[:space:]]*$//'
}

# Parse a human operator answer into a simple allow/deny decision.
ralph_permission_operator_response_decision() {
  local text="${1:-}"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  if [[ "$text" =~ ^[[:space:]]*\{ ]]; then
    if command -v jq >/dev/null 2>&1; then
      local json_decision=""
      json_decision="$(printf '%s' "$text" | jq -r '.decision // empty' 2>/dev/null || true)"
      case "$(printf '%s' "$json_decision" | tr '[:upper:]' '[:lower:]')" in
        allow|approve|approved|yes|y)
          printf 'allow\n'
          return 0
          ;;
        deny|decline|declined|reject|rejected|no|n)
          printf 'deny\n'
          return 0
          ;;
      esac
    fi
  fi

  if printf '%s\n' "$lower" | grep -qE '(^|[^[:alnum:]])(allow|approve|approved|yes|y)([^[:alnum:]]|$)'; then
    printf 'allow\n'
    return 0
  fi

  if printf '%s\n' "$lower" | grep -qE '(^|[^[:alnum:]])(deny|decline|declined|reject|rejected|no|n)([^[:alnum:]]|$)'; then
    printf 'deny\n'
    return 0
  fi

  printf 'unknown\n'
}

ralph_write_human_request_artifact() {
  local session_dir="${1:-}"
  local kind="${2:-guidance}"
  local runtime="${3:-}"
  local todo_line="${4:-0}"
  local todo_text="${5:-}"
  local full_line="${6:-}"
  local classification="${7:-}"
  local blocked_cmd_or_tool="${8:-}"
  local blocked_path="${9:-}"
  local blocked_tool="${10:-}"
  local request_text="${11:-}"
  local denial_excerpt="${12:-}"
  local hint="${13:-}"
  local resume_cmd="${14:-}"
  local question_text="${15:-}"
  local py="${SCRIPT_DIR:-}/python/permission-remediation-artifact.py"
  if [[ ! -f "$py" ]] || ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  local tmp out legacy_out
  tmp="$(mktemp -d "${session_dir%/}/.ralph-human-request.XXXXXX")" || return 1
  out="${session_dir%/}/human-request.json"
  legacy_out="${session_dir%/}/permission-remediation.json"
  printf '%s' "$kind" >"$tmp/kind.one"
  printf '%s' "$runtime" >"$tmp/runtime.one"
  printf '%s' "$todo_line" >"$tmp/todo_line.one"
  printf '%s' "$todo_text" >"$tmp/todo.txt"
  printf '%s' "$full_line" >"$tmp/full_line.txt"
  printf '%s' "$classification" >"$tmp/classification.one"
  printf '%s' "$blocked_cmd_or_tool" >"$tmp/blocked_cmd_or_tool.one"
  printf '%s' "$blocked_path" >"$tmp/blocked_path.one"
  printf '%s' "$blocked_tool" >"$tmp/blocked_tool.one"
  printf '%s' "$request_text" >"$tmp/question.txt"
  printf '%s' "$denial_excerpt" >"$tmp/denial.txt"
  printf '%s' "$hint" >"$tmp/hint.txt"
  printf '%s' "$resume_cmd" >"$tmp/resume.txt"
  python3 -c '
import json
import pathlib
import sys

indir = pathlib.Path(sys.argv[1])
meta = {
    "kind": (indir / "kind.one").read_text(encoding="utf-8", errors="replace").strip() or "guidance",
    "runtime": (indir / "runtime.one").read_text(encoding="utf-8", errors="replace").strip(),
    "todo_line": int((indir / "todo_line.one").read_text(encoding="utf-8", errors="replace").strip() or "0"),
    "classification": (indir / "classification.one").read_text(encoding="utf-8", errors="replace"),
    "blocked_command_or_tool": (indir / "blocked_cmd_or_tool.one").read_text(encoding="utf-8", errors="replace"),
    "blocked_path": (indir / "blocked_path.one").read_text(encoding="utf-8", errors="replace"),
    "blocked_tool": (indir / "blocked_tool.one").read_text(encoding="utf-8", errors="replace"),
    "session_strategy": "fresh",
    "denial_excerpt_max_bytes": 8192,
}
(indir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
' "$tmp" || {
    rm -rf "$tmp"
    return 1
  }
  if ! python3 "$py" "$tmp" "$out"; then
    rm -rf "$tmp"
    return 1
  fi
  if [[ "${kind:-guidance}" == "permission" ]]; then
    cp -f "$out" "$legacy_out"
  fi
  rm -rf "$tmp"
  printf '%s\n' "$out"
}

# Ask the operator to allow or deny one permission request on the terminal.
# Prints "allow" or "deny" on stdout; returns 1 when no answer could be read,
# which is not the same as a deny and must never be recorded as one.
#
# Shared by the pause-and-resume path and the live in-band approval path so
# both honor RALPH_PERMISSION_RESPONSE_DECISION and read the terminal the same
# way. The prompt itself goes to /dev/tty, never stdout: stdout belongs to the
# runtime's output pipeline.
ralph_permission_prompt_operator_decision() {
  local prompt_text="${1:-}"
  local decision="" read_rc=0

  if [[ -n "${RALPH_PERMISSION_RESPONSE_DECISION:-}" ]]; then
    case "$(printf '%s' "$RALPH_PERMISSION_RESPONSE_DECISION" | tr '[:upper:]' '[:lower:]')" in
      y|yes|allow) printf 'allow\n' ;;
      *) printf 'deny\n' ;;
    esac
    return 0
  fi

  { [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; } || return 1

  printf '%s' "$prompt_text" >/dev/tty
  # The CLI process may have left the terminal in raw or non-blocking mode.
  # Reset to canonical blocking mode and drain any buffered keystrokes that
  # accumulated while the agent was running; both calls are no-op on failure.
  stty sane </dev/tty 2>/dev/null || true
  # A literal `-t 0` here is a trap on bash 4.2+: per the manual, timeout 0
  # only *polls* whether input is available and does not consume it, so if
  # any byte is already buffered this becomes an infinite loop instead of a
  # drain (reproduced with GNU bash 5.3 under a real pty). A small positive
  # timeout actually reads and discards each buffered line, then exits once
  # nothing more arrives within the window.
  while IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null; do :; done 2>/dev/null || true
  IFS= read -r decision </dev/tty || read_rc=$?
  if [[ "$read_rc" -ne 0 ]]; then
    return 1
  fi
  case "$(printf '%s' "$decision" | tr '[:upper:]' '[:lower:]')" in
    y|yes|allow) printf 'allow\n' ;;
    *) printf 'deny\n' ;;
  esac
}

# Ask the operator to type a free-text answer to a guidance question on the
# terminal. Prints the answer on stdout; returns 1 when no answer could be
# read (no tty, EOF, or the operator left it blank), which must never be
# recorded as an empty answer.
#
# Mirrors ralph_permission_prompt_operator_decision above: honors a
# pre-approved answer via RALPH_GUIDANCE_RESPONSE_ANSWER, otherwise reads the
# terminal directly so the operator never has to leave the session to edit
# operator-response.txt by hand. The prompt itself goes to /dev/tty, never
# stdout: stdout belongs to the runtime's output pipeline.
ralph_guidance_prompt_operator_answer() {
  local prompt_text="${1:-}"
  local answer="" read_rc=0

  if [[ -n "${RALPH_GUIDANCE_RESPONSE_ANSWER:-}" ]]; then
    printf '%s\n' "$RALPH_GUIDANCE_RESPONSE_ANSWER"
    return 0
  fi

  { [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; } || return 1

  printf '%s' "$prompt_text" >/dev/tty
  stty sane </dev/tty 2>/dev/null || true
  # A literal `-t 0` here is a trap on bash 4.2+: per the manual, timeout 0
  # only *polls* whether input is available and does not consume it, so if
  # any byte is already buffered this becomes an infinite loop instead of a
  # drain (reproduced with GNU bash 5.3 under a real pty). A small positive
  # timeout actually reads and discards each buffered line, then exits once
  # nothing more arrives within the window.
  while IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null; do :; done 2>/dev/null || true
  IFS= read -r answer </dev/tty || read_rc=$?
  if [[ "$read_rc" -ne 0 ]]; then
    return 1
  fi
  [[ -n "$answer" ]] || return 1
  printf '%s\n' "$answer"
}

# Best-effort path pattern for OpenCode permission approval.
ralph_permission_opencode_external_directory_pattern() {
  local blocked_path="${1:-}"
  if [[ -n "$blocked_path" ]]; then
    printf '%s\n' "$blocked_path"
    return 0
  fi
  printf '%s\n' '/tmp/*'
}

# Determine the active killswitch configuration path without considering any
# session-local override file.
ralph_killswitch_active_config_path() {
  if [[ -n "${WORKSPACE:-}" && -f "$WORKSPACE/.ralph-workspace/killswitch.json" ]]; then
    printf '%s\n' "$WORKSPACE/.ralph-workspace/killswitch.json"
    return 0
  fi
  if [[ -n "${RALPH_HOME:-}" && -f "${RALPH_HOME}/killswitch.json" ]]; then
    printf '%s\n' "${RALPH_HOME}/killswitch.json"
    return 0
  fi
  local script_dir="${SCRIPT_DIR:-}"
  if [[ -z "$script_dir" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  if [[ -f "$script_dir/killswitch.json" ]]; then
    printf '%s\n' "$script_dir/killswitch.json"
    return 0
  fi
  return 1
}

# Write a session-local killswitch overlay that allows one previously blocked
# command, path, or tool pattern.
ralph_write_killswitch_permission_overlay() {
  local session_dir="${1:-}"
  local blocked_cmd="${2:-}"
  local blocked_path="${3:-}"
  local blocked_tool="${4:-}"
  local overlay_path
  local base_path
  local tmp_path
  [[ -n "$session_dir" ]] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  overlay_path="${session_dir%/}/killswitch-override.json"
  base_path="$(ralph_killswitch_active_config_path 2>/dev/null || true)"
  tmp_path="$(mktemp "${session_dir%/}/.ralph-killswitch-override-XXXXXX")" || return 1

  if [[ -n "$base_path" && -f "$base_path" ]]; then
    cp "$base_path" "$tmp_path" || {
      rm -f "$tmp_path"
      return 1
    }
  else
    jq -n '{
      schema_version: 2,
      enabled: true,
      dry_run: false,
      banned_tools: [],
      allowed_tools: [],
      banned_paths: [],
      allowed_paths: [],
      allowed_commands: [],
      allowed_patterns: [],
      custom_rules: []
    }' >"$tmp_path" || {
      rm -f "$tmp_path"
      return 1
    }
  fi

  local jq_filter='.'
  if [[ -n "$blocked_tool" ]]; then
    jq_filter+=" | .allowed_tools = ((.allowed_tools // []) + [\$blocked_tool] | unique)"
  fi
  if [[ -n "$blocked_path" ]]; then
    jq_filter+=" | .allowed_paths = ((.allowed_paths // []) + [\$blocked_path] | unique)"
  fi
  if [[ -n "$blocked_cmd" ]]; then
    jq_filter+=" | .allowed_commands = ((.allowed_commands // []) + [\$blocked_cmd] | unique)"
  fi
  if [[ "$jq_filter" == "." ]]; then
    rm -f "$tmp_path"
    return 1
  fi

  if ! jq -c \
    --arg blocked_tool "$blocked_tool" \
    --arg blocked_path "$blocked_path" \
    --arg blocked_cmd "$blocked_cmd" \
    "$jq_filter" \
    "$tmp_path" >"$overlay_path"; then
    rm -f "$tmp_path" "$overlay_path"
    return 1
  fi

  rm -f "$tmp_path"
  printf '%s\n' "$overlay_path"
}

# Write or update a session-local OpenCode permission overlay that allows one
# previously blocked external_directory path pattern.
ralph_write_opencode_permission_overlay() {
  local session_dir="${1:-}"
  local blocked_path="${2:-}"
  local overlay_path
  local tmp_path
  local pattern

  [[ -n "$session_dir" ]] || return 1
  pattern="$(ralph_permission_opencode_external_directory_pattern "$blocked_path")"
  overlay_path="${session_dir%/}/opencode-permission-override.json"

  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  tmp_path="$(mktemp "${session_dir%/}/.ralph-opencode-permission-XXXXXX")" || return 1
  if [[ -f "$overlay_path" ]]; then
    if ! jq -c \
      --arg pattern "$pattern" \
      '
      .permission = (
        (.permission // {}) + {
          external_directory: ((.permission.external_directory // {}) + {($pattern): "allow"})
        }
      )
      ' "$overlay_path" >"$tmp_path"; then
      rm -f "$tmp_path"
      return 1
    fi
  else
    if ! jq -n \
      --arg pattern "$pattern" \
      '{permission: {external_directory: {($pattern): "allow"}}}' >"$tmp_path"; then
      rm -f "$tmp_path"
      return 1
    fi
  fi
  mv "$tmp_path" "$overlay_path"
  printf '%s\n' "$overlay_path"
}

ralph_write_session_mcp_allowlist() {
  local session_dir="${1:-}"
  local blocked_path="${2:-}"
  local allow_entries=()
  local parent_dir=""
  local resolved_path=""

  [[ -n "$session_dir" ]] || return 1
  [[ -n "$blocked_path" ]] || return 1

  if [[ "$blocked_path" == /* ]]; then
    resolved_path="$blocked_path"
  else
    resolved_path="$(cd "$session_dir" 2>/dev/null && pwd -P)/$blocked_path"
  fi

  if [[ -n "$resolved_path" ]]; then
    allow_entries+=("$resolved_path")
    parent_dir="$(dirname "$resolved_path")"
    if [[ -n "$parent_dir" && "$parent_dir" != "." ]]; then
      allow_entries+=("$parent_dir")
    fi
  fi

  if [[ "${#allow_entries[@]}" -eq 0 ]]; then
    return 1
  fi

  if declare -F ralph_session_append_mcp_allowlist_entries >/dev/null 2>&1; then
    ralph_session_append_mcp_allowlist_entries "${allow_entries[@]}"
    return $?
  fi

  local file="${RALPH_MCP_ALLOWLIST_FILE:-${session_dir%/}/mcp-allowlist.txt}"
  mkdir -p "$(dirname "$file")" || return 1
  touch "$file" || return 1
  local entry
  for entry in "${allow_entries[@]}"; do
    if ! grep -Fxq -- "$entry" "$file" 2>/dev/null; then
      printf '%s\n' "$entry" >> "$file" || return 1
    fi
  done
  local merged="${RALPH_MCP_ALLOWLIST:-}"
  for entry in "${allow_entries[@]}"; do
    merged="$(ralph_permission_union_csv "$merged" "$entry")"
  done
  RALPH_MCP_ALLOWLIST="$merged"
  export RALPH_MCP_ALLOWLIST
  return 0
}

# Join two comma-separated permission lists while preserving order and removing
# duplicates. Empty items are ignored.
ralph_permission_union_csv() {
  local left="${1:-}"
  local right="${2:-}"
  local -a items=()
  local -A seen=()
  local -a merged=()
  local source item trimmed

  for source in "$left" "$right"; do
    [[ -n "$source" ]] || continue
    IFS=',' read -ra items <<< "$source"
    for item in "${items[@]}"; do
      trimmed="${item#"${item%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [[ -z "$trimmed" ]] && continue
      if [[ -z "${seen[$trimmed]:-}" ]]; then
        seen["$trimmed"]=1
        merged+=("$trimmed")
      fi
    done
  done

  if [[ ${#merged[@]} -gt 0 ]]; then
    local old_ifs="$IFS"
    IFS=','
    printf '%s' "${merged[*]}"
    IFS="$old_ifs"
  fi
}

# Best-effort conversion from a denied path or glob pattern to a Codex add-dir
# root. Returns nothing when the value cannot be turned into a usable directory.
ralph_codex_permission_add_dir_root() {
  local blocked_path="${1:-}"
  if [[ -z "$blocked_path" ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 - "$blocked_path" <<'PY'
import os
import re
import sys

path = sys.argv[1].strip()
if not path:
    sys.exit(0)

wildcard = re.search(r'[*?\[]', path)
if wildcard:
    path = path[:wildcard.start()]
    path = path.rstrip("/ ")

if not path:
    sys.exit(0)

if os.path.isdir(path):
    print(os.path.abspath(path))
else:
    parent = os.path.dirname(path) or "."
    print(os.path.abspath(parent))
PY
}

# Write a session-local shell overlay containing runtime-specific permission
# exceptions that should be reloaded on the next retry.
ralph_write_runtime_permission_overlay() {
  local session_dir="${1:-}"
  local runtime="${2:-}"
  local classification="${3:-}"
  local blocked_cmd="${4:-}"
  local blocked_path="${5:-}"
  local blocked_tool="${6:-}"
  local overlay_path
  local tmp_path
  local wrote=0

  [[ -n "$session_dir" ]] || return 1
  overlay_path="${session_dir%/}/runtime-permission-overrides.sh"
  tmp_path="$(mktemp "${session_dir%/}/.ralph-runtime-perm-XXXXXX")" || return 1

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Session-local runtime permission overrides generated by Ralph.'

    case "$runtime" in
      claude)
        local base_tools merged_tools
        base_tools="${CLAUDE_PLAN_ALLOWED_TOOLS:-${CLAUDE_TOOLS_FROM_AGENT:-Bash,Read,Edit,Write}}"
        case "$classification" in
          restricted_tool|approval_rejected|permission_unknown)
            merged_tools="$(ralph_permission_union_csv "$base_tools" "$blocked_tool")"
            ;;
          *)
            merged_tools="$(ralph_permission_union_csv "$base_tools" "$blocked_tool")"
            ;;
        esac
        if [[ -n "$merged_tools" ]]; then
          printf 'export CLAUDE_PLAN_ALLOWED_TOOLS=%q\n' "$merged_tools"
          CLAUDE_PLAN_ALLOWED_TOOLS="$merged_tools"
          export CLAUDE_PLAN_ALLOWED_TOOLS
          wrote=1
        fi
        if [[ -n "${CLAUDE_PLAN_PERMISSION_MODE:-}" ]]; then
          printf 'export CLAUDE_PLAN_PERMISSION_MODE=%q\n' "$CLAUDE_PLAN_PERMISSION_MODE"
          export CLAUDE_PLAN_PERMISSION_MODE
          wrote=1
        fi
        ;;
      codex)
        local add_dir base_dirs merged_dirs
        add_dir=""
        case "$classification" in
          sandbox_path|external_directory|permission_unknown)
            add_dir="$(ralph_codex_permission_add_dir_root "$blocked_path" 2>/dev/null || true)"
            ;;
        esac
        if [[ -n "$add_dir" ]]; then
          base_dirs="${CODEX_PLAN_EXTRA_ADD_DIRS:-}"
          merged_dirs="$(ralph_permission_union_csv "$base_dirs" "$add_dir")"
          printf 'export CODEX_PLAN_EXTRA_ADD_DIRS=%q\n' "$merged_dirs"
          CODEX_PLAN_EXTRA_ADD_DIRS="$merged_dirs"
          export CODEX_PLAN_EXTRA_ADD_DIRS
          wrote=1
        fi
        ;;
      *)
        :
        ;;
    esac
  } >"$tmp_path"

  if [[ "$wrote" -eq 0 ]]; then
    rm -f "$tmp_path"
    return 1
  fi

  mv "$tmp_path" "$overlay_path"
  printf '%s\n' "$overlay_path"
}

# Consume a permission remediation response and persist approvals when allowed.
ralph_apply_permission_operator_response() {
  local session_dir="${1:-}"
  local runtime="${2:-}"
  local classification="${3:-}"
  local blocked_cmd="${4:-}"
  local blocked_path="${5:-}"
  local blocked_tool="${6:-}"
  local response_text="${7:-}"
  local decision
  local runtime_overlay_path=""

  # Best-effort overlay writes must never overturn the operator's answer. When
  # one fails, the approval still stands and this records why enforcement may
  # be weaker than requested so the caller can warn.
  RALPH_PERMISSION_APPLY_DEGRADED=""
  export RALPH_PERMISSION_APPLY_DEGRADED

  decision="$(ralph_permission_operator_response_decision "$response_text")"
  case "$decision" in
    allow)
      if [[ -n "$blocked_cmd" || -n "$blocked_path" || -n "$blocked_tool" ]]; then
        local ks_overlay=""
        if ks_overlay="$(ralph_write_killswitch_permission_overlay \
          "$session_dir" \
          "$blocked_cmd" \
          "$blocked_path" \
          "$blocked_tool" 2>/dev/null)"; then
          RALPH_KILLSWITCH_OVERRIDE_FILE="$ks_overlay"
          export RALPH_KILLSWITCH_OVERRIDE_FILE
        fi
      fi
      if runtime_overlay_path="$(ralph_write_runtime_permission_overlay \
        "$session_dir" \
        "$runtime" \
        "$classification" \
        "$blocked_cmd" \
        "$blocked_path" \
        "$blocked_tool" 2>/dev/null)"; then
        RALPH_RUNTIME_PERMISSION_OVERRIDES_FILE="$runtime_overlay_path"
        export RALPH_RUNTIME_PERMISSION_OVERRIDES_FILE
      fi
      if [[ "$classification" == "external_directory" ]]; then
        local overlay_path=""
        if overlay_path="$(ralph_write_opencode_permission_overlay "$session_dir" "$blocked_path" 2>/dev/null)"; then
          OPENCODE_PLAN_PERMISSION_CONFIG_PATH="$overlay_path"
          export OPENCODE_PLAN_PERMISSION_CONFIG_PATH
        else
          RALPH_PERMISSION_APPLY_DEGRADED="opencode-overlay"
        fi
        # A denial excerpt does not always yield a concrete path. Without one
        # there is nothing to add to the proxy allowlist, but that is a gap in
        # what we could extract -- not an operator decision. Record it and keep
        # the approval.
        if [[ -n "$blocked_path" ]]; then
          if ! ralph_write_session_mcp_allowlist "$session_dir" "$blocked_path"; then
            RALPH_PERMISSION_APPLY_DEGRADED="${RALPH_PERMISSION_APPLY_DEGRADED:+${RALPH_PERMISSION_APPLY_DEGRADED},}mcp-allowlist"
          fi
        else
          RALPH_PERMISSION_APPLY_DEGRADED="${RALPH_PERMISSION_APPLY_DEGRADED:+${RALPH_PERMISSION_APPLY_DEGRADED},}no-blocked-path"
        fi
      fi
      ;;
  esac

  printf '%s\n' "$decision"
}

# Write structured permission remediation JSON under the plan session directory.
ralph_write_permission_remediation_artifact() {
  local session_dir="$1"
  local runtime="$2"
  local todo_line="$3"
  local todo_text="$4"
  local full_line="$5"
  local classification="$6"
  local blocked_cmd_or_tool="$7"
  local blocked_path="$8"
  local blocked_tool="${9:-}"
  local denial_excerpt="${10:-}"
  local hint="${11:-}"
  local resume_cmd="${12:-}"
  local py="${SCRIPT_DIR:-}/python/permission-remediation-artifact.py"
  if [[ ! -f "$py" ]]; then
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  local tmp out
  tmp="$(mktemp -d "${session_dir%/}/.ralph-perm-rem.XXXXXX")" || return 1
  out="${session_dir%/}/permission-remediation.json"
  printf '%s' "permission" >"$tmp/kind.one"
  printf '%s' "$todo_text" >"$tmp/todo.txt"
  printf '%s' "$full_line" >"$tmp/full_line.txt"
  printf '%s' "$todo_text" >"$tmp/question.txt"
  printf '%s' "$denial_excerpt" >"$tmp/denial.txt"
  printf '%s' "$hint" >"$tmp/hint.txt"
  printf '%s' "$resume_cmd" >"$tmp/resume.txt"
  printf '%s' "$runtime" >"$tmp/runtime.one"
  printf '%s' "$todo_line" >"$tmp/todo_line.one"
  printf '%s' "$classification" >"$tmp/classification.one"
  printf '%s' "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" >"$tmp/session_strategy.one"
  printf '%s' "$blocked_cmd_or_tool" >"$tmp/blocked_cmd_or_tool.one"
  printf '%s' "$blocked_path" >"$tmp/blocked_path.one"
  printf '%s' "$blocked_tool" >"$tmp/blocked_tool.one"
  python3 -c '
import json
import pathlib
import sys

def one(p):
    return pathlib.Path(p).read_text(encoding="utf-8", errors="replace").strip()

indir = pathlib.Path(sys.argv[1])
meta = {
    "kind": one(indir / "kind.one") if (indir / "kind.one").is_file() else "permission",
    "runtime": one(indir / "runtime.one"),
    "session_strategy": one(indir / "session_strategy.one") if (indir / "session_strategy.one").is_file() else "fresh",
    "todo_line": int(one(indir / "todo_line.one")),
    "classification": one(indir / "classification.one"),
    "blocked_command_or_tool": pathlib.Path(indir / "blocked_cmd_or_tool.one").read_text(
        encoding="utf-8", errors="replace"
    ),
    "blocked_path": pathlib.Path(indir / "blocked_path.one").read_text(
        encoding="utf-8", errors="replace"
    ),
    "blocked_tool": pathlib.Path(indir / "blocked_tool.one").read_text(
        encoding="utf-8", errors="replace"
    ),
    "denial_excerpt_max_bytes": 8192,
}
(indir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
' "$tmp" || {
    rm -rf "$tmp"
    return 1
  }
  if ! python3 "$py" "$tmp" "$out"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  return 0
}

# Heuristic sub-classification for Claude restricted_tool hints (stdout: one of
# permission_mode, write_edit, tool_policy, generic).
ralph_claude_restricted_subkind() {
  local text="${1:-}"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  if printf '%s\n' "$lower" | grep -qE 'permission[[:space:]]+mode|permission.*mode.*(restrict|deny|block|disallow|forbidden|not allowed)|mode.*(restrict|deny|block).*tool'; then
    printf 'permission_mode\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE '(write|edit)[[:space:]]+tool|create[[:space:]]+file|write[[:space:]]+file|edit[[:space:]]+file|file.*(not allowed|denied|permission).*write'; then
    printf 'write_edit\n'
    return 0
  fi
  if printf '%s\n' "$lower" | grep -qE 'tool.*(not allowed|disallowed|blocked|denied|not permitted|not authorized)|allowedtools|allowed tools'; then
    printf 'tool_policy\n'
    return 0
  fi
  printf 'generic\n'
}

# Optional trimmed stderr block for Codex hints (fourth arg to ralph_permission_hint).
ralph_codex_denial_detail() {
  local denial_excerpt="${1:-}"
  if [[ -z "$denial_excerpt" ]]; then
    printf ''
    return 0
  fi
  printf '\n\nCodex stderr excerpt (trimmed):\n%s' "$(printf '%s' "$denial_excerpt" | head -c 800)"
  if [[ "${#denial_excerpt}" -gt 800 ]]; then
    printf ' [...]'
  fi
}

# Optional trimmed stderr block for OpenCode hints (fourth arg to ralph_permission_hint).
ralph_opencode_denial_detail() {
  local denial_excerpt="${1:-}"
  if [[ -z "$denial_excerpt" ]]; then
    printf ''
    return 0
  fi
  printf '\n\nOpenCode output excerpt (trimmed):\n%s' "$(printf '%s' "$denial_excerpt" | head -c 800)"
  if [[ "${#denial_excerpt}" -gt 800 ]]; then
    printf ' [...]'
  fi
}

ralph_permission_hint() {
  local block_type="${1:-}"
  local runtime="${2:-}"
  local blocked_cmd="${3:-}"
  local denial_excerpt="${4:-}"
  case "$block_type" in
    allowlist_command)
      case "$runtime" in
        cursor)
          local cmd_part=""
          if [[ -n "$blocked_cmd" ]]; then
            cmd_part="

Blocked command: $blocked_cmd"
          fi
          printf 'Cursor blocked a command because it is not in the allowlist.%s

What Cursor is asking: Cursor wants your approval before running a shell command that is not in its pre-approved list. You can choose "Run once" to allow this single invocation, "Add Shell(...) to allowlist" to permanently approve it, or "Auto-run everything" to skip all future prompts (not recommended).

Recommended choices:
  - Run once: Best for one-off commands (reads, status checks, non-destructive queries). Approve only this invocation without future auto-approval.
  - Add Shell(...) to allowlist: Best for recurring trusted commands (e.g., build, test, lint). Adds the command to the allowlist so Cursor will not ask again. Only add commands you trust to run unsupervised.
  - Auto-run everything: Skip all future approval prompts. Not recommended except in fully isolated environments.' "$cmd_part"
          ;;
        *) printf 'Add the blocked command to the runtime allowlist or approve it when prompted.' ;;
      esac
      ;;
    sandbox_path)
      case "$runtime" in
        codex)
          local cx_lower="" cx_detail=""
          cx_lower="$(printf '%s' "$denial_excerpt" | tr '[:upper:]' '[:lower:]')"
          cx_detail="$(ralph_codex_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          local primary=""
          if printf '%s\n' "$cx_lower" | grep -qE 'read[- ]only|read only|writes? (are )?disabled|write.*disabled.*sandbox|cannot write.*sandbox'; then
            primary="Strongest match: broader Codex sandbox preset (often read-only). This is not fixed by adding a single --add-dir if the whole workspace is read-only.
"
          elif printf '%s\n' "$cx_lower" | grep -qE 'sandbox path|path (denied|not accessible|not allowed)|outside.*writable|not visible to'; then
            primary="Strongest match: writable-path / visibility. Codex refused a path that was not mounted into the exec sandbox (missing --add-dir or wrong directory).
"
          else
            primary="Codex refused path access inside its sandbox. Compare the stderr lines to the three categories below.
"
          fi
          printf '%s
Codex blocked a sandbox path (filesystem access inside the Codex container).

What kind of unblock?
  1) Writable-path / directory visibility: the tool needs a host path Ralph did not pass to codex exec. Non-resume runs add workspace and .ralph-workspace via --add-dir when enabled; anything else needs an explicit writable path. Re-run with CODEX_PLAN_SANDBOX=workspace-write (default) and ensure the target lives under an added directory, or extend the Ralph Codex wrapper so codex exec receives --add-dir for that root.

  2) Broader sandbox preset: CODEX_PLAN_SANDBOX controls codex exec --sandbox (read-only, workspace-write, danger-full-access). If the denial mentions read-only or write-disabled, widen the preset before chasing paths. danger-full-access removes sandbox protections; use only on isolated machines.

  3) Host permission rule: host wrapper, enterprise policy, or macOS privacy (Full Disk Access) can deny reads/writes even when Codex flags look correct. If the excerpt mentions host wrapper or system policy, fix the host side rather than Ralph flags alone.%s' "$primary" "$cx_detail"
          ;;
        opencode)
          local oc_lower="" oc_detail=""
          oc_lower="$(printf '%s' "$denial_excerpt" | tr '[:upper:]' '[:lower:]')"
          oc_detail="$(ralph_opencode_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          local oc_note=""
          if printf '%s\n' "$oc_lower" | grep -qE 'read-only|read only file system|eacces|permission denied.*path|path.*not allowed'; then
            oc_note="Strongest match: filesystem or sandbox boundary. OpenCode blocked a read or write outside what your permission rules or a sandbox plugin allows.
"
          else
            oc_note="OpenCode refused path or sandboxed filesystem access. Compare the excerpt to your permission rules and any sandbox plugin limits.
"
          fi
          printf '%sOpenCode blocked a sandbox or path-level filesystem operation.

How OpenCode decides this: tool calls are checked against the `permission` object in ~/.config/opencode/opencode.json (and project-local OpenCode config when present). Rules are per tool (for example bash, read, edit) with outcomes allow, ask, or deny. A sandbox plugin (if installed) can further restrict writes to the project tree and specific temp paths.

What to try next (OpenCode):
  - Narrow the fix: allow the exact path pattern or bash prefix shown in the log under the right tool key, or change a deny rule to ask while you debug interactively.
  - Re-run with an attended terminal if the rule is ask so you can choose once or always only for patterns you trust.
  - If you use headless `opencode run` via Ralph: prefer explicit allow rules for recurring commands; ask prompts may not be answerable in CI.
  - Use `opencode --print-logs` when the excerpt is too short to see which rule matched.%s' "$oc_note" "$oc_detail"
          ;;
        *) printf 'Add the required path to the runtime sandbox writable-paths or allowed-directories configuration.' ;;
      esac
      ;;
    external_directory)
      case "$runtime" in
        codex)
          local cx_detail=""
          cx_detail="$(ralph_codex_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          printf 'Codex rejected access outside the writable workspace roots (external directory rejection).

Primary unblock category: writable-path / workspace boundary. Add the needed directory with codex exec --add-dir (Ralph forwards extra dirs from CODEX_PLAN_EXTRA_ADD_DIRS via bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh when configured), or copy artifacts into the workspace tree so Codex only touches paths inside the sandbox.

If you already added the directory but still see this message, check CODEX_PLAN_SANDBOX (read-only cannot write even allowed paths) and whether a host wrapper blocked the mount.

Broader sandbox escalation (danger-full-access) is a last resort on trusted hosts only; it does not replace fixing the wrong working directory or missing --add-dir.%s' "$cx_detail"
          ;;
        opencode)
          local oc_detail=""
          oc_detail="$(ralph_opencode_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          printf 'OpenCode blocked access that matched the external_directory permission guard (paths outside the workspace boundary OpenCode treats as external).

What OpenCode is doing: the `external_directory` permission kind defaults to ask in OpenCode; deny or unanswered ask runs surface as rejections when the model tries to touch host paths outside allowed roots.

What to try next (OpenCode):
  - Add or widen a rule under permission.external_directory (or the merged permission map) to allow the specific directory pattern, or move artifacts into the workspace so tools only touch project-local paths.
  - If the UI offered once / always / reject: pick once for a single path, or always only when the pattern is intentionally broad and trusted.
  - Headless runs need explicit allow rules; there is no interactive click path in Ralph-owned automation.%s' "$oc_detail"
          ;;
        *) printf 'Move the operation into the workspace directory or grant the runtime access to the external directory.' ;;
      esac
      ;;
    restricted_tool)
      case "$runtime" in
        claude)
          local subkind=""
          subkind="$(ralph_claude_restricted_subkind "$denial_excerpt" 2>/dev/null || true)"
          [[ -z "$subkind" ]] && subkind="generic"
          local detail=""
          if [[ -n "$denial_excerpt" ]]; then
            detail="

Denial excerpt (from Claude output):
$(printf '%s' "$denial_excerpt" | head -c 800)"
            if [[ "${#denial_excerpt}" -gt 800 ]]; then
              detail+=" [...]"
            fi
          fi
          case "$subkind" in
            permission_mode)
              printf 'Claude blocked this because your permission mode or plan policy rejected the tool or edit.%s

What to try next (Claude only):
  - Interactive Claude Code: rerun and approve the action when Claude prompts. If prompts never appear, set CLAUDE_PLAN_PERMISSION_MODE (or run-plan --claude-permission-mode) to a mode that matches the work, for example acceptEdits or plan. See docs/ENVIRONMENT.md for each mode; modes such as auto, bypassPermissions, or dontAsk skip prompts and are unsafe on shared machines.

  - Headless or CI: the CLI cannot answer interactive permission prompts. Pre-authorize tools instead: extend allowed_tools in the agent config, set CLAUDE_PLAN_ALLOWED_TOOLS, or pass run-plan --tools so the needed tool names (Write, Edit, Bash, etc.) match the task. Tight permission modes still require the tool surface to allow the operation.' "$detail"
              ;;
            write_edit)
              printf 'Claude blocked file changes because Write/Edit (or equivalent) is not allowed under the current allowed-tools or permission configuration.%s

What to try next (Claude only):
  - Widen allowed tools: add Write and Edit via the agent config allowed_tools field, CLAUDE_PLAN_ALLOWED_TOOLS, or run-plan --tools (comma list as Claude expects).

  - If edits are blocked by permission mode rather than the tool list: adjust CLAUDE_PLAN_PERMISSION_MODE / --claude-permission-mode (for example acceptEdits) after reading docs/ENVIRONMENT.md.

  - If you intended to approve manually: rerun interactively and approve the edit tool when Claude asks.' "$detail"
              ;;
            tool_policy)
              printf 'Claude refused a tool call because the tool name is not permitted under the current allowed-tools list or permission rules.%s

What to try next (Claude only):
  - Add the missing tool to allowed_tools (agent JSON), CLAUDE_PLAN_ALLOWED_TOOLS, or run-plan --tools so headless runs include it.

  - If the tool is permitted but execution was still blocked by policy: change CLAUDE_PLAN_PERMISSION_MODE / --claude-permission-mode, or approve in the Claude UI on interactive reruns.' "$detail"
              ;;
            *)
              printf 'Claude blocked a tool or edit for permission reasons.%s

What to try next (Claude only):
  - Approve in Claude Code when a permission prompt appears, or rerun interactively if the last run was non-interactive.

  - Widen allowed tools: agent allowed_tools, CLAUDE_PLAN_ALLOWED_TOOLS, or run-plan --tools.

  - Relax or retarget permission mode: CLAUDE_PLAN_PERMISSION_MODE or --claude-permission-mode (see docs/ENVIRONMENT.md; high-trust modes reduce safety).' "$detail"
              ;;
          esac
          ;;
        cursor) printf 'Enable the blocked tool in the Cursor agent settings or allow it in the runtime configuration.' ;;
        opencode)
          local oc_detail=""
          oc_detail="$(ralph_opencode_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          printf 'OpenCode refused this tool because it is disabled, not enabled for this agent, or denied by permission rules.

What OpenCode is doing: OpenCode keys permissions by tool name (for example bash, read, edit, glob, grep, task) with per-pattern allow, ask, or deny outcomes in ~/.config/opencode/opencode.json. A missing or deny rule blocks the call before execution.

What to try next (OpenCode):
  - Locate the tool named in the error and add an allow rule for the command or path pattern you intend, or change deny to ask while testing interactively.
  - Agent JSON from Ralph only selects the agent profile; tool availability still follows OpenCode permission config and enabled plugins.
  - Re-run with `opencode --print-logs` if the stderr line does not name the blocked tool clearly.%s' "$oc_detail"
          ;;
        *) printf 'Enable the blocked tool in the runtime permission or tool configuration.' ;;
      esac
      ;;
    network_or_host_restriction)
      case "$runtime" in
        codex)
          local cx_lower="" cx_detail=""
          cx_lower="$(printf '%s' "$denial_excerpt" | tr '[:upper:]' '[:lower:]')"
          cx_detail="$(ralph_codex_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          local net_note=""
          if printf '%s\n' "$cx_lower" | grep -qE 'sandbox|policy|not allowed|blocked by'; then
            net_note="Strongest match: Codex sandbox or CLI policy blocked the network call. workspace-write still restricts some egress; read-only is tighter. Compare with host firewall rules if the message also mentions the OS or proxy.
"
          else
            net_note="Could be Codex sandbox network limits or a host-side firewall, proxy, or DNS policy. Read the excerpt to see which side is named.
"
          fi
          printf '%sCodex network or host access was denied.

Triage:
  - Broader sandbox / CLI: CODEX_PLAN_SANDBOX and codex exec flags may forbid outbound access. Widen only in trusted environments (see docs for danger-full-access).

  - Host permission rule: corporate VPN, proxy, /etc/hosts, or local firewall blocks show up here even when Codex sandbox is already permissive. Fix the host route or allowlist the endpoint outside Ralph.

  - Writable-path is usually not the root cause for pure network errors unless the tool is trying to read credentials from an unmounted path (then fix --add-dir first).%s' "$net_note" "$cx_detail"
          ;;
        *) printf 'Network or host access was denied. Check the runtime network/sandbox configuration and allow the required host or endpoint.' ;;
      esac
      ;;
    approval_rejected)
      case "$runtime" in
        cursor)
          local cmd_part=""
          if [[ -n "$blocked_cmd" ]]; then
            cmd_part="
Blocked command: $blocked_cmd"
          fi
          printf 'A Cursor approval prompt was rejected (e.g., "Run this command?" or "Auto-run everything" dismissal).%s

What happened: Cursor asked for your permission to run a command, and the prompt was dismissed or denied. The command was not executed.

How to resolve:
  - Re-run the plan: when the approval prompt appears again, choose "Run once" for a single invocation or "Add Shell(...) to allowlist" for recurring trusted commands.
  - Pre-approve: add the command to the Cursor allowlist via .cursorrules or the Cursor settings UI so the prompt does not appear next time.' "$cmd_part"
          ;;
        claude)
          local appr_detail=""
          if [[ -n "$denial_excerpt" ]]; then
            appr_detail="

Denial excerpt (from Claude output):
$(printf '%s' "$denial_excerpt" | head -c 800)"
            if [[ "${#denial_excerpt}" -gt 800 ]]; then
              appr_detail+=" [...]"
            fi
          fi
          printf 'Claude did not execute a tool because user approval was denied, dismissed, or unavailable in this session.%s

What to try next (Claude only):
  - Interactive runs: rerun the plan and approve the tool in the Claude Code UI when prompted. Keep the terminal session attended if Ralph runs Claude in the foreground.

  - Headless / non-interactive: there is no prompt to approve. Add the tool to allowed_tools in the agent config, set CLAUDE_PLAN_ALLOWED_TOOLS, or pass run-plan --tools so Claude is allowed to use it without a prompt.

  - If approval failed because the permission mode is too strict for the requested work: adjust CLAUDE_PLAN_PERMISSION_MODE or --claude-permission-mode only in trusted workspaces (see docs/ENVIRONMENT.md).' "$appr_detail"
          ;;
        codex)
          local cx_lower="" cx_detail=""
          cx_lower="$(printf '%s' "$denial_excerpt" | tr '[:upper:]' '[:lower:]')"
          cx_detail="$(ralph_codex_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          local appr_note=""
          if printf '%s\n' "$cx_lower" | grep -qE 'explicit(ly)?|user (reject|denied|declined)|operator|dismiss|cancelled|canceled'; then
            appr_note="Strongest match: host permission rule (explicit user approval rejection). You or the operator declined the Codex approval UI; widening --add-dir or CODEX_PLAN_SANDBOX will not substitute for approving the prompt.
"
          else
            appr_note="Treat this as a host permission rule until proven otherwise: Codex asked for approval and the run did not proceed.
"
          fi
          printf '%sCodex did not run the action because an on-request approval was rejected or dismissed.

What to do (Codex):
  - Re-run interactively and approve when Codex prompts (host-side rule: your explicit choice at the prompt).

  - Headless automation cannot click approvals. Use a non-interactive approvals preset only where your org allows it, or run with attended terminals.

  - This is not the same as a missing writable path: if the log only mentions approval or user rejection, fix approval flow first; use --add-dir only when the log also shows external-directory or sandbox path denials.%s' "$appr_note" "$cx_detail"
          ;;
        opencode)
          local oc_lower="" oc_detail=""
          oc_lower="$(printf '%s' "$denial_excerpt" | tr '[:upper:]' '[:lower:]')"
          oc_detail="$(ralph_opencode_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          local oc_appr=""
          if printf '%s\n' "$oc_lower" | grep -qE 'reject|declined|denied|cancel|canceled|dismiss'; then
            oc_appr="Strongest match: interactive permission outcome was reject (or deny resolved without a successful once/always choice).
"
          else
            oc_appr="OpenCode reported an approval or permission prompt outcome that blocked execution.
"
          fi
          printf '%sOpenCode did not run the tool because a permission prompt ended with reject, or the matching rule resolved to deny.

What OpenCode is doing: when a tool matches permission mode ask, the UI offers once (single approval), always (remember a safe pattern for this session), or reject. Deny rules skip the prompt entirely.

What to try next (OpenCode):
  - Interactive: rerun `opencode run` or the OpenCode UI flow and choose once for a one-off command, or always only when the suggested pattern is intentionally narrow and trusted.
  - Headless / Ralph-driven runs: update ~/.config/opencode/opencode.json so the tool pattern is allow instead of ask/deny, or run from a TTY when you need attended approvals.
  - If you intended deny: change the task or paths so it stays within allowed patterns instead of overriding safety rules.%s' "$oc_appr" "$oc_detail"
          ;;
        *) printf 'The approval prompt was rejected. Re-run and approve when prompted, or adjust the runtime permission configuration for automatic approval.' ;;
      esac
      ;;
    permission_unknown)
      case "$runtime" in
        codex)
          local cx_lower="" cx_detail=""
          cx_lower="$(printf '%s' "$denial_excerpt" | tr '[:upper:]' '[:lower:]')"
          cx_detail="$(ralph_codex_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          if printf '%s\n' "$cx_lower" | grep -qE 'host.*(wrapper|side)|escalat.*permission'; then
            printf 'Codex reported a host-wrapper or host-side permission escalation failure.

Primary unblock category: host permission rule. The macOS/Linux wrapper around codex exec, MDM, or system integrity blocked the action. Review host logs and wrapper configuration; Ralph --add-dir and CODEX_PLAN_SANDBOX changes may not be enough until the host allows the operation.

Secondary checks: confirm CODEX_PLAN_SANDBOX is not unexpectedly read-only, and that any required paths are still passed via --add-dir.%s' "$cx_detail"
          else
            printf 'Codex hit a permission-related failure that does not map cleanly to sandbox path, external directory, or approval wording.

Triage order:
  1) Writable-path: add missing --add-dir roots for the paths in the excerpt.
  2) Broader sandbox: CODEX_PLAN_SANDBOX and codex exec policy vs read-only / workspace-write.
  3) Host permission rule: OS privacy, wrapper, or enterprise agent if the excerpt mentions host, wrapper, or system denial.%s' "$cx_detail"
          fi
          ;;
        opencode)
          local oc_detail=""
          oc_detail="$(ralph_opencode_denial_detail "$denial_excerpt" 2>/dev/null || true)"
          printf 'OpenCode reported a permission-related failure that does not map cleanly to a single sandbox path, external_directory rule, or explicit reject line.

Triage order (OpenCode):
  1) Permission map: read ~/.config/opencode/opencode.json permission entries for the tool named in the log (bash, read, edit, etc.). Look for deny, missing allow patterns, or ask in unattended contexts.
  2) Path scope: move work under the workspace root or add explicit allow patterns for required external paths instead of relying on broad wildcards.
  3) Plugins and host OS: sandbox plugins and macOS privacy tools can still block reads/writes even when OpenCode rules look permissive; compare the excerpt to host-level denials.

If the log text is ambiguous and could be another layer, still start with the permission map above, then fall back to generic sandbox and tool permission checks on the host.%s' "$oc_detail"
          ;;
        *) ralph_permission_hint_permission_unknown_fallback "$runtime" "$denial_excerpt" ;;
      esac
      ;;
    *)
      printf '' ;;
  esac
}

# Generic fallback guidance when runtime-specific remediation cannot name the approval workflow.
ralph_permission_hint_permission_unknown_fallback() {
  local runtime="${1:-}"
  local denial_excerpt="${2:-}"
  local rt_note=""
  if [[ -n "$runtime" ]]; then
    rt_note=" Runtime: $runtime."
  fi
  printf 'Ralph could not identify the exact approval workflow for this denial.%s

A permission block was detected but the specific cause is unclear. Compare the stderr excerpt to your runtime sandbox, allowlist, tool permissions, and any approval UI that may still be open. If the excerpt names a command or path, unblock that scope first; otherwise adjust the narrowest matching policy for the tool that failed.' "$rt_note"
  if [[ -n "${denial_excerpt//[$' \t\n']/}" ]]; then
    printf '\n\nDenial excerpt (trimmed):\n%s' "$(printf '%s' "$denial_excerpt" | head -c 800)"
    if [[ "${#denial_excerpt}" -gt 800 ]]; then
      printf ' [...]'
    fi
  fi
}

# Vendor-visible approval hints for permission-pause operator briefs (pending-human, human-replies, human action files).
ralph_permission_vendor_prompt_hint() {
  local runtime="${1:-}"
  local classification="${2:-}"
  case "$runtime" in
    cursor)
      case "$classification" in
        allowlist_command)
          printf '%s\n' "- In Cursor: if you see **Not in allowlist** or **Run this command?**, choose **Run once** for a single shot, or **Add Shell(...)** when the command should recur."
          printf '%s\n' "- Avoid **Auto-run everything** unless the machine and repo are fully isolated."
          ;;
        approval_rejected)
          printf '%s\n' "- In Cursor: if **Run this command?** reappears on rerun, choose **Run once** or add the shown Shell(...) pattern to the allowlist instead of dismissing the prompt."
          ;;
        *)
          printf '%s\n' "- In Cursor: answer any shell approval or allowlist dialog that matches the blocked command shown above."
          ;;
      esac
      ;;
    claude)
      printf '%s\n' "- In Claude Code: approve the pending tool or edit banner when it appears, or switch to an interactive rerun if the last attempt was headless."
      ;;
    codex)
      printf '%s\n' "- In Codex: approve the CLI/host approval widget when it appears (workspace-write and --add-dir do not replace an explicit rejection you chose earlier)."
      ;;
    opencode)
      printf '%s\n' "- In OpenCode: pick **once** or **always** on the tool permission prompt when it appears; **reject** or deny rules stop the run until config changes."
      ;;
    *)
      printf '%s\n' "- In your assistant runtime UI: approve the pending tool or command action if a prompt is still visible."
      ;;
  esac
}

# Full operator brief for permission blocks (pending-human, human-replies, HUMAN_ACTION_REQUIRED, session stub).
# Args: line_num todo_text plan_path runtime classification hint resume_cmd [denial_excerpt] [blocked_cmd] [blocked_path]
ralph_build_permission_operator_brief() {
  local line_num="${1:?}"
  local todo_text="${2:?}"
  local plan_path="${3:?}"
  local runtime="${4:?}"
  local classification="${5:?}"
  local hint="${6:-}"
  local resume_cmd="${7:-}"
  local denial_excerpt="${8:-}"
  local blocked_cmd="${9:-}"
  local blocked_path="${10:-}"
  local guidance="${hint:-}"
  if [[ -z "${guidance//[$' \t\n']/}" ]]; then
    if declare -F ralph_permission_hint_permission_unknown_fallback >/dev/null 2>&1; then
      guidance="$(ralph_permission_hint_permission_unknown_fallback "$runtime" "$denial_excerpt" 2>/dev/null || true)"
    fi
    if [[ -z "${guidance//[$' \t\n']/}" ]]; then
      guidance="Ralph classified a permission block but did not generate runtime-specific guidance text. Read the stderr excerpt and your runtime docs, then adjust allowlists, sandbox mounts, agent allowed_tools, OpenCode permission JSON, or Codex --add-dir / CODEX_PLAN_SANDBOX as appropriate."
    fi
  fi

  printf 'Permission block (%s) on line %s: %s\n\n' "$classification" "$line_num" "$todo_text"
  printf '%s\n\n' "The CLI stopped after the runtime refused a permission-gated action. The checkbox stays open until you unblock the runtime and rerun with the same plan context."
  if [[ "$classification" == "permission_unknown" ]]; then
    printf '%s\n\n' "Ralph could not identify the exact approval workflow for this block. Use the excerpts and blocked command/path fields below, then follow the unblock and rerun sections."
  fi
  printf '%s\n' "## Where you were"
  printf '%s\n' "- Plan file: $plan_path"
  printf '%s\n' "- Open TODO line: $line_num"
  printf '%s\n' "- Runtime: $runtime"
  printf '%s\n' "- Session strategy: ${RALPH_PLAN_SESSION_STRATEGY:-fresh}"
  printf '%s\n' "- Classification: $classification"
  printf '\n'

  if [[ -n "${blocked_cmd//[$' \t\n']/}" ]]; then
    printf '%s\n' "## Blocked command or tool (best effort)"
    printf '%s\n\n' "$blocked_cmd"
  fi
  if [[ -n "${blocked_path//[$' \t\n']/}" ]]; then
    printf '%s\n' "## Blocked path (best effort)"
    printf '%s\n\n' "$blocked_path"
  fi

  if [[ -n "${denial_excerpt//[$' \t\n']/}" ]]; then
    printf '%s\n' "## Raw denial excerpt (trimmed)"
    printf '%s' "$(printf '%s' "$denial_excerpt" | head -c 1200)"
    if [[ "${#denial_excerpt}" -gt 1200 ]]; then
      printf ' [...]'
    fi
    printf '\n\n'
  fi

  printf '%s\n' "## Operator guidance"
  printf '%s\n\n' "$guidance"

  printf '%s\n' "## Unblock this runtime"
  printf '%s\n' "### If a vendor approval or permission prompt is still visible"
  printf '\n'
  ralph_permission_vendor_prompt_hint "$runtime" "$classification"
  printf '\n'
  if [[ "$runtime" == "opencode" ]]; then
    printf '%s\n' "Update the structured JSON response in \`operator-response.txt\` with a real decision, remove or flip \`placeholder\` to \`false\`, and set \`decision\":\"allow\"\` to write a session-local OpenCode permission override and retry this TODO, or set \`decision\":\"deny\"\` to stop here."
    printf '\n'
  fi
  printf '%s\n' "### If no prompt is visible on screen"
  printf '%s\n' "- Apply the configuration or allowlist changes described under **Operator guidance** above (agent JSON, environment variables, Cursor allowlist, Codex sandbox flags, or OpenCode permission rules)."
  printf '%s\n' "- Inspect the structured record in your session directory: \`human-request.json\` (and \`permission-remediation.json\` for permission pauses) in the same folder as \`pending-human.txt\`."
  printf '\n'
  printf '%s\n' "### Rerun this TODO"
  if [[ -n "${resume_cmd//[$' \t\n']/}" ]]; then
    printf '%s\n' "After unblocking, rerun from your workspace using this shell command (copy as one line). It preserves the same plan, runtime, session strategy, and open TODO:"
    printf '\n'
    printf '%s\n' '```'
    printf '%s\n' "$resume_cmd"
    printf '%s\n' '```'
    printf '\n'
    case "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" in
      checkpoint)
        printf '%s\n' "Checkpoint mode keeps a fresh CLI per TODO and does not pass runtime --resume flags; checkpoint files under your session directory carry bounded context."
        ;;
      resume|reset)
        printf '%s\n' "Resume/reset mode reuses the stored CLI session id when one exists under your session directory."
        ;;
      *)
        printf '%s\n' "Fresh mode starts a new CLI session for the next TODO after you rerun."
        ;;
    esac
  else
    printf '%s\n' "After unblocking, rerun this plan from the repository root with the same \`--runtime\`, \`--plan\`, \`--workspace\`, and session-related environment variables you used before. Ralph could not reconstruct an exact one-liner in this environment."
  fi
}

ralph_permission_block_type() {
  local text="${1:-}"
  local exit_code="${2:-0}"
  local runtime="${3:-}"
  local result
  if ralph_permission_is_runtime_bootstrap_failure "$text"; then
    printf 'none\n'
    return 0
  fi
  if result="$(ralph_classify_permission_block "$text" "$exit_code" "$runtime" 2>/dev/null)"; then
    printf '%s\n' "$result"
  elif result="$(ralph_classify_permission_block_fallback "$text" "$exit_code" "$runtime" 2>/dev/null)"; then
    printf '%s\n' "$result"
  else
    printf 'none\n'
  fi
}
