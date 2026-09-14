#!/usr/bin/env bash
# Shared graph approval-adapter contract.
#
# This module owns capability discovery, G15 permission-record normalization,
# common decision translation, the run-local reversible overlay fallback, and
# the G16 approval continuation transaction. Discovery is fail-closed: a
# capability is supported only when a static proof or an explicit proof object
# says so. Missing, malformed, aliased, or vague values stay unsupported and
# are listed in `unsupported`. Callers must not infer live streaming from
# session continuation, same-operation response from live streaming, or one
# lifetime from another. Permission records advertise only choices/lifetimes
# proved by capabilities. allow-once is offered only when same-operation
# response or a narrow reversible overlay can enforce it; deny remains stronger.
#
# Decision translation maps a Ralph decision onto a native lifetime and
# proves the native grant is equal to or narrower than the Ralph request.
# Auto, force, yolo, dangerously-skip-permissions, and sandbox bypass are
# never valid permission-response fallbacks.
#
# Lifetimes in this contract are native-adapter lifetimes:
#   once, run, always-policy
# Ralph project allow-always policy is not a native lifetime and is never
# guessed from `once` or `run`.
#
# Output is one compact JSON object:
#   {
#     schemaVersion,
#     runtime,
#     liveRequestStreaming,
#     sameOperationResponse,
#     sessionContinuation,
#     lifetimes: {once, run, always-policy},
#     supported,   # names that are true
#     unsupported  # names that are false; always complete for the rest
#   }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${RALPH_RUN_PLAN_APPROVAL_ADAPTER_LOADED:-}" ]]; then
  return 0
fi
RALPH_RUN_PLAN_APPROVAL_ADAPTER_LOADED=1

_RALPH_APPROVAL_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RALPH_APPROVAL_ADAPTER_SCHEMA_VERSION=1
RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS=()
RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS=()
RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED=()
RALPH_APPROVAL_ADAPTER_COMPACT_TURN_USED=0
RALPH_APPROVAL_ADAPTER_KNOWN_RUNTIMES='antigravity
claude
codex
cursor
opencode'

# ralph_approval_adapter_trim <value>
ralph_approval_adapter_trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ralph_approval_adapter_normalize_runtime <runtime>
# Lowercase, map underscores to hyphens, trim. Empty stays empty.
ralph_approval_adapter_normalize_runtime() {
  local raw
  raw="$(ralph_approval_adapter_trim "${1-}")"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

# ralph_approval_adapter_is_known_runtime <runtime>
ralph_approval_adapter_is_known_runtime() {
  local runtime="$1" candidate
  [[ -n "$runtime" ]] || return 1
  while IFS= read -r candidate; do
    [[ "$candidate" == "$runtime" ]] && return 0
  done <<< "$RALPH_APPROVAL_ADAPTER_KNOWN_RUNTIMES"
  return 1
}

# ralph_approval_adapter_is_explicit_true <jq-compact-value>
# Only JSON true, the string "true" (any case), or number 1 count.
# "yes", "on", "auto", "maybe", "unknown", and "unsupported" do not.
ralph_approval_adapter_is_explicit_true() {
  local raw
  raw="$(ralph_approval_adapter_trim "${1-}")"
  case "$raw" in
    true|True|TRUE) return 0 ;;
    '"true"'|'"True"'|'"TRUE"') return 0 ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

# ralph_approval_adapter_proof_is_object <json>
ralph_approval_adapter_proof_is_object() {
  local proof="${1-}"
  [[ -n "$proof" ]] || return 1
  printf '%s' "$proof" | jq -e 'type == "object"' >/dev/null 2>&1
}

# ralph_approval_adapter_proof_has <json> <jq-expr-returning-object> <key>
ralph_approval_adapter_proof_has() {
  local proof="$1" object_expr="$2" key="$3"
  printf '%s' "$proof" | jq -e --arg k "$key" \
    "($object_expr | type == \"object\") and ($object_expr | has(\$k))" \
    >/dev/null 2>&1
}

# ralph_approval_adapter_proof_flag <json> <object-expr> <key> <default>
# Explicit key: true only when the value is an explicit true.
# Missing key: keep <default> (true/false). Never infer from aliases.
ralph_approval_adapter_proof_flag() {
  local proof="$1" object_expr="$2" key="$3" default="${4:-false}" raw
  if ! ralph_approval_adapter_proof_has "$proof" "$object_expr" "$key"; then
    printf '%s' "$default"
    return 0
  fi
  raw="$(printf '%s' "$proof" | jq -c --arg k "$key" "$object_expr[\$k]" 2>/dev/null)" || raw=""
  if ralph_approval_adapter_is_explicit_true "$raw"; then
    printf 'true'
  else
    printf 'false'
  fi
}

# ralph_approval_adapter_bool_word <true|false>
# Normalize to the jq literals true/false; anything else is false.
ralph_approval_adapter_bool_word() {
  case "${1-}" in
    true) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# ralph_approval_adapter_choices_from_capabilities <capabilities-json>
# Maps proved lifetimes onto Ralph operator choices. always-policy is the only
# path to allow-always. Deny is always included for an actionable request.
# Prints one compact JSON object: {choices:[...], lifetimes:[...]}.
ralph_approval_adapter_choices_from_capabilities() {
  local caps="${1-}"
  if [[ -z "$caps" ]] || ! printf '%s' "$caps" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval adapter choices require a capabilities JSON object" >&2
    return 1
  fi
  jq -nc --argjson caps "$caps" '
    def life($name):
      ($caps.lifetimes | type) == "object" and ($caps.lifetimes[$name] == true);
    {
      choices: (
        []
        + (if life("once") then ["allow-once"] else [] end)
        + (if life("run") then ["allow-run"] else [] end)
        + (if life("always-policy") then ["allow-always"] else [] end)
        + ["deny"]
      ),
      lifetimes: (
        []
        + (if life("once") then ["once"] else [] end)
        + (if life("run") then ["run"] else [] end)
        + (if life("always-policy") then ["always-policy"] else [] end)
      )
    }
  '
}

# ralph_approval_adapter_permission_unknown <runtime> <reason>
# Compact non-actionable G15 rejection (classification unknown).
ralph_approval_adapter_permission_unknown() {
  local runtime="${1:-}"
  local reason="${2:-permission request is not actionable}"
  runtime="$(ralph_approval_adapter_normalize_runtime "$runtime")"
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "{\"schemaVersion\":1,\"runtime\":\"${runtime}\",\"actionable\":false,\"classification\":\"unknown\",\"reason\":\"${reason}\"}"
    return 0
  fi
  jq -nc --arg runtime "$runtime" --arg reason "$reason" '{
    schemaVersion: 1,
    runtime: $runtime,
    actionable: false,
    classification: "unknown",
    reason: $reason
  }'
}

# ralph_approval_adapter_normalize_tool_tuple <tool> <action> <effect>
# Canonicalizes tool/action/effect without broadening a proved read into write.
# Prints compact JSON {tool,action,effect} or returns 1 when unmappable.
ralph_approval_adapter_normalize_tool_tuple() {
  local tool action effect
  tool="$(ralph_approval_adapter_trim "${1-}" | tr '[:upper:]' '[:lower:]')"
  action="$(ralph_approval_adapter_trim "${2-}" | tr '[:upper:]' '[:lower:]')"
  effect="$(ralph_approval_adapter_trim "${3-}" | tr '[:upper:]' '[:lower:]')"

  case "$tool" in
    bash|shell)
      tool="bash"
      [[ -n "$action" ]] || action="execute"
      [[ -n "$effect" ]] || effect="write"
      ;;
    edit|write|patch)
      [[ -n "$action" ]] || action="edit"
      [[ -n "$effect" ]] || effect="write"
      ;;
    read|glob|grep)
      [[ -n "$action" ]] || action="read"
      [[ -n "$effect" ]] || effect="read"
      ;;
    webfetch|websearch)
      [[ -n "$action" ]] || action="fetch"
      [[ -n "$effect" ]] || effect="network"
      ;;
    *)
      if [[ -z "$tool" ]]; then
        return 1
      fi
      [[ -n "$action" ]] || action="$tool"
      [[ -n "$effect" ]] || effect="write"
      ;;
  esac

  case "$effect" in
    read|write|network) ;;
    edit|shell) effect="write" ;;
    *) effect="write" ;;
  esac

  jq -nc --arg tool "$tool" --arg action "$action" --arg effect "$effect" \
    '{tool:$tool, action:$action, effect:$effect}'
}

# ralph_approval_adapter_build_permission_record <fields-json> <capabilities-json>
# Elevates a proved identity into the G15 actionable permission request
# contract. Choices and lifetimes come only from capabilities -- never invent
# allow-always / always-policy when the adapter cannot enforce them.
#
# Required fields: runtime, sessionId, nativeRequestId, tool, action, resource,
# effect. Optional: reason, expiresAt.
#
# Prints one compact JSON object. Exit 0 when input is JSON; callers must check
# .actionable. Exit 1 only for empty/malformed input or missing jq.
ralph_approval_adapter_build_permission_record() {
  local fields="${1-}"
  local caps="${2-}"
  local reason_max=200
  local choice_doc choices_json lifetimes_json
  local runtime session_id request_id tool action resource effect reason expires
  local mapped

  if [[ -z "$fields" ]]; then
    echo "Error: approval adapter permission record requires a fields JSON object" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for approval adapter permission records" >&2
    return 1
  fi
  if ! printf '%s' "$fields" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval adapter permission record fields must be a JSON object" >&2
    return 1
  fi

  runtime="$(ralph_approval_adapter_normalize_runtime "$(printf '%s' "$fields" | jq -r '.runtime // empty')")"
  session_id="$(ralph_approval_adapter_trim "$(printf '%s' "$fields" | jq -r '.sessionId // .sessionID // .session // empty')")"
  request_id="$(ralph_approval_adapter_trim "$(printf '%s' "$fields" | jq -r '.nativeRequestId // .requestId // .id // empty')")"
  tool="$(ralph_approval_adapter_trim "$(printf '%s' "$fields" | jq -r '.tool // empty')")"
  action="$(ralph_approval_adapter_trim "$(printf '%s' "$fields" | jq -r '.action // empty')")"
  resource="$(ralph_approval_adapter_trim "$(printf '%s' "$fields" | jq -r '.resource // empty')")"
  effect="$(ralph_approval_adapter_trim "$(printf '%s' "$fields" | jq -r '.effect // empty')")"
  reason="$(ralph_approval_adapter_trim "$(printf '%s' "$fields" | jq -r '.reason // empty')")"
  expires="$(printf '%s' "$fields" | jq -c '.expiresAt // null')"

  if [[ "$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')" == "permission"
        && "$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')" == "permission"
        && "$(printf '%s' "$effect" | tr '[:upper:]' '[:lower:]')" == "write" ]]; then
    ralph_approval_adapter_permission_unknown "$runtime" \
      "generic permission/permission/write is not actionable"
    return 0
  fi

  if [[ -z "$runtime" || -z "$session_id" || -z "$request_id" || -z "$resource" ]]; then
    ralph_approval_adapter_permission_unknown "$runtime" \
      "permission event is missing actionable identity"
    return 0
  fi

  if ! mapped="$(ralph_approval_adapter_normalize_tool_tuple "$tool" "$action" "$effect")"; then
    ralph_approval_adapter_permission_unknown "$runtime" \
      "permission event is missing actionable tool identity"
    return 0
  fi
  tool="$(printf '%s' "$mapped" | jq -r '.tool')"
  action="$(printf '%s' "$mapped" | jq -r '.action')"
  effect="$(printf '%s' "$mapped" | jq -r '.effect')"

  if [[ "$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')" == "permission"
        && "$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')" == "permission"
        && "$effect" == "write" ]]; then
    ralph_approval_adapter_permission_unknown "$runtime" \
      "generic permission/permission/write is not actionable"
    return 0
  fi

  # Proved read must not broaden to write.
  if [[ "$(printf '%s' "$fields" | jq -r '.effect // empty' | tr '[:upper:]' '[:lower:]')" == "read"
        && "$effect" != "read" ]]; then
    ralph_approval_adapter_permission_unknown "$runtime" \
      "permission parse must not convert a read request into a write effect"
    return 0
  fi

  if [[ -z "$caps" ]] || ! printf '%s' "$caps" | jq -e 'type == "object"' >/dev/null 2>&1; then
    caps="$(ralph_approval_adapter_capabilities "$runtime")"
  fi
  choice_doc="$(ralph_approval_adapter_choices_from_capabilities "$caps")" || return 1
  choices_json="$(printf '%s' "$choice_doc" | jq -c '.choices')"
  lifetimes_json="$(printf '%s' "$choice_doc" | jq -c '.lifetimes')"

  if [[ -z "$reason" ]]; then
    reason="${runtime} ${tool} ${action} requires approval for ${resource}"
  fi
  if ((${#reason} > reason_max)); then
    reason="${reason:0:$((reason_max - 3))}..."
  fi

  jq -nc \
    --arg runtime "$runtime" \
    --arg session "$session_id" \
    --arg request_id "$request_id" \
    --arg tool "$tool" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    --arg reason "$reason" \
    --argjson choices "$choices_json" \
    --argjson lifetimes "$lifetimes_json" \
    --argjson expires "$expires" \
    '{
      schemaVersion: 1,
      runtime: $runtime,
      actionable: true,
      sessionId: $session,
      nativeRequestId: $request_id,
      tool: $tool,
      action: $action,
      resource: $resource,
      effect: $effect,
      choices: $choices,
      lifetimes: $lifetimes,
      reason: $reason,
      expiresAt: $expires
    }'
}

# ralph_approval_adapter_capabilities [runtime] [proof-json]
#
# Static matrix (no CLI probe, no model call):
#   known invoke runtimes: sessionContinuation=true
#   all other capabilities and all lifetimes: unsupported
#
# Optional proof-json may enable or disable a field only when that exact
# canonical key is present. Snake_case, aliases, and omitted keys are not
# treated as support.
ralph_approval_adapter_capabilities() {
  local runtime proof
  local live same session
  local life_once life_run life_always

  runtime="$(ralph_approval_adapter_normalize_runtime "${1-}")"
  proof="${2-}"

  live=false
  same=false
  session=false
  life_once=false
  life_run=false
  life_always=false

  if ralph_approval_adapter_is_known_runtime "$runtime"; then
    session=true
  fi

  if ralph_approval_adapter_proof_is_object "$proof"; then
    live="$(ralph_approval_adapter_proof_flag "$proof" '.' 'liveRequestStreaming' "$live")"
    same="$(ralph_approval_adapter_proof_flag "$proof" '.' 'sameOperationResponse' "$same")"
    session="$(ralph_approval_adapter_proof_flag "$proof" '.' 'sessionContinuation' "$session")"
    if printf '%s' "$proof" | jq -e '.lifetimes | type == "object"' >/dev/null 2>&1; then
      life_once="$(ralph_approval_adapter_proof_flag "$proof" '.lifetimes' 'once' "$life_once")"
      life_run="$(ralph_approval_adapter_proof_flag "$proof" '.lifetimes' 'run' "$life_run")"
      life_always="$(ralph_approval_adapter_proof_flag "$proof" '.lifetimes' 'always-policy' "$life_always")"
    fi
  fi

  live="$(ralph_approval_adapter_bool_word "$live")"
  same="$(ralph_approval_adapter_bool_word "$same")"
  session="$(ralph_approval_adapter_bool_word "$session")"
  life_once="$(ralph_approval_adapter_bool_word "$life_once")"
  life_run="$(ralph_approval_adapter_bool_word "$life_run")"
  life_always="$(ralph_approval_adapter_bool_word "$life_always")"

  jq -nc \
    --arg runtime "$runtime" \
    --argjson schema "$RALPH_APPROVAL_ADAPTER_SCHEMA_VERSION" \
    --argjson live "$live" \
    --argjson same "$same" \
    --argjson session "$session" \
    --argjson once "$life_once" \
    --argjson runlt "$life_run" \
    --argjson always "$life_always" \
    '{
      schemaVersion: $schema,
      runtime: $runtime,
      liveRequestStreaming: $live,
      sameOperationResponse: $same,
      sessionContinuation: $session,
      lifetimes: {
        once: $once,
        run: $runlt,
        "always-policy": $always
      }
    }
    | . as $doc
    | ($doc + {
        supported: (
          []
          + (if $doc.liveRequestStreaming then ["liveRequestStreaming"] else [] end)
          + (if $doc.sameOperationResponse then ["sameOperationResponse"] else [] end)
          + (if $doc.sessionContinuation then ["sessionContinuation"] else [] end)
          + (if $doc.lifetimes.once then ["lifetime:once"] else [] end)
          + (if $doc.lifetimes.run then ["lifetime:run"] else [] end)
          + (if $doc.lifetimes["always-policy"] then ["lifetime:always-policy"] else [] end)
        ),
        unsupported: (
          []
          + (if $doc.liveRequestStreaming then [] else ["liveRequestStreaming"] end)
          + (if $doc.sameOperationResponse then [] else ["sameOperationResponse"] end)
          + (if $doc.sessionContinuation then [] else ["sessionContinuation"] end)
          + (if $doc.lifetimes.once then [] else ["lifetime:once"] end)
          + (if $doc.lifetimes.run then [] else ["lifetime:run"] end)
          + (if $doc.lifetimes["always-policy"] then [] else ["lifetime:always-policy"] end)
        )
      })'
}

# ralph_approval_adapter_capability_is_supported <capabilities-json> <name>
# <name> is liveRequestStreaming, sameOperationResponse, sessionContinuation,
# a lifetime token (once|run|always-policy), or lifetime:<token>.
ralph_approval_adapter_capability_is_supported() {
  local json="${1-}" name="${2-}"
  [[ -n "$json" && -n "$name" ]] || return 1
  printf '%s' "$json" | jq -e --arg n "$name" '
    if $n == "liveRequestStreaming" then .liveRequestStreaming == true
    elif $n == "sameOperationResponse" then .sameOperationResponse == true
    elif $n == "sessionContinuation" then .sessionContinuation == true
    elif ($n | startswith("lifetime:")) then
      .lifetimes[$n[9:]] == true
    else
      .lifetimes[$n] == true
    end
  ' >/dev/null 2>&1
}

RALPH_APPROVAL_ADAPTER_DECISIONS='allow-once
allow-run
allow-always
deny'

RALPH_APPROVAL_ADAPTER_EFFECTS='read
write
network'

# ralph_approval_adapter_has_dotdot <path>
# True when any slash-separated component is `..`.
ralph_approval_adapter_has_dotdot() {
  local path="$1" rest component
  rest="$path"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$component" == ".." ]]; then
      return 0
    fi
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
  done
  return 1
}

# ralph_approval_adapter_token_in_list <token> <newline-list>
ralph_approval_adapter_token_in_list() {
  local token="$1" candidate
  [[ -n "$token" ]] || return 1
  while IFS= read -r candidate; do
    [[ "$candidate" == "$token" ]] && return 0
  done <<< "$2"
  return 1
}

# ralph_approval_adapter_normalize_effect <effect>
ralph_approval_adapter_normalize_effect() {
  printf '%s' "$(ralph_approval_adapter_trim "${1-}")" | tr '[:upper:]' '[:lower:]'
}

# ralph_approval_adapter_normalize_resource <resource>
# Trim, strip leading ./, collapse duplicate slashes. Keep a trailing slash
# so a directory-prefix request can still be proven narrower.
ralph_approval_adapter_normalize_resource() {
  local resource
  resource="$(ralph_approval_adapter_trim "${1-}")"
  if [[ -z "$resource" || "$resource" == *$'\n'* || "$resource" == *$'\r'* ]]; then
    echo "Error: approval adapter resource must be a non-empty single line" >&2
    return 1
  fi
  if ralph_approval_adapter_has_dotdot "$resource"; then
    echo "Error: approval adapter resource may not contain '..'" >&2
    return 1
  fi
  while [[ "$resource" == ./* ]]; do
    resource="${resource#./}"
  done
  while [[ "$resource" == *//* ]]; do
    resource="${resource//\/\//\/}"
  done
  if [[ -z "$resource" ]]; then
    echo "Error: approval adapter resource must be a non-empty single line" >&2
    return 1
  fi
  printf '%s' "$resource"
}

# ralph_approval_adapter_decision_to_lifetime <ralph-decision>
# allow-once->once, allow-run->run, allow-always->always-policy, deny->deny.
ralph_approval_adapter_decision_to_lifetime() {
  case "$(ralph_approval_adapter_trim "${1-}")" in
    allow-once) printf 'once' ;;
    allow-run) printf 'run' ;;
    allow-always) printf 'always-policy' ;;
    deny) printf 'deny' ;;
    *) return 1 ;;
  esac
}

# ralph_approval_adapter_lifetime_rank <lifetime>
# deny=0, once=1, run=2, always-policy=3. Unknown fails.
ralph_approval_adapter_lifetime_rank() {
  case "$(ralph_approval_adapter_trim "${1-}")" in
    deny) printf '0' ;;
    once) printf '1' ;;
    run) printf '2' ;;
    always-policy) printf '3' ;;
    *) return 1 ;;
  esac
}

# ralph_approval_adapter_effect_is_exact_or_narrower <requested> <granted>
# write->read is narrower. network is only exact. Broader or orthogonal fails.
ralph_approval_adapter_effect_is_exact_or_narrower() {
  local requested="$1" granted="$2"
  [[ -n "$requested" && -n "$granted" ]] || return 1
  if [[ "$granted" == "$requested" ]]; then
    return 0
  fi
  if [[ "$requested" == "write" && "$granted" == "read" ]]; then
    return 0
  fi
  return 1
}

# ralph_approval_adapter_resource_is_exact_or_narrower <requested> <granted>
# Exact match always passes. A concrete path under a requested directory or
# trailing glob is narrower. A wildcard grant that is not identical is not
# narrower. Parent paths and expanded globs fail.
ralph_approval_adapter_resource_is_exact_or_narrower() {
  local requested="$1" granted="$2" prefix
  if [[ -z "$requested" || -z "$granted" ]]; then
    return 1
  fi
  if [[ "$granted" == "$requested" ]]; then
    return 0
  fi
  if ralph_approval_adapter_has_dotdot "$granted"; then
    return 1
  fi
  case "$granted" in
    *'*'*|*'?'*)
      return 1
      ;;
  esac
  if [[ "$requested" == *'/**' ]]; then
    prefix="${requested%'/**'}"
    [[ -n "$prefix" && ( "$granted" == "$prefix" || "$granted" == "$prefix"/* ) ]]
    return $?
  fi
  if [[ "$requested" == *'/*' ]]; then
    prefix="${requested%'/*'}"
    [[ -n "$prefix" && "$granted" == "$prefix"/* && "$granted" != "$prefix"/*/* ]]
    return $?
  fi
  if [[ "$requested" == */ ]]; then
    prefix="${requested%/}"
    [[ -n "$prefix" && "$granted" == "$prefix"/* ]]
    return $?
  fi
  return 1
}

# ralph_approval_adapter_grant_is_exact_or_narrower <req-action> <req-resource> \
#   <req-effect> <grant-action> <grant-resource> <grant-effect>
ralph_approval_adapter_grant_is_exact_or_narrower() {
  local req_action="$1" req_resource="$2" req_effect="$3"
  local grant_action="$4" grant_resource="$5" grant_effect="$6"
  if [[ "$grant_action" != "$req_action" ]]; then
    echo "Error: approval adapter grant action must match the request action" >&2
    return 1
  fi
  if ! ralph_approval_adapter_effect_is_exact_or_narrower "$req_effect" "$grant_effect"; then
    echo "Error: approval adapter native grant is broader than the Ralph request" >&2
    return 1
  fi
  if ! ralph_approval_adapter_resource_is_exact_or_narrower "$req_resource" "$grant_resource"; then
    echo "Error: approval adapter native grant is broader than the Ralph request" >&2
    return 1
  fi
  return 0
}

# ralph_approval_adapter_is_dangerous_fallback <value>
# True when the value names auto, force, yolo, dangerously-skip-permissions,
# or a sandbox/approvals bypass. Empty is not dangerous.
ralph_approval_adapter_is_dangerous_fallback() {
  local raw lowered rest part stripped
  raw="$(ralph_approval_adapter_trim "${1-}")"
  [[ -n "$raw" ]] || return 1
  lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  case "$lowered" in
    *'sandbox bypass'*|*'bypass sandbox'*|*'skip permissions'*) return 0 ;;
    *'dangerously-skip-permissions'*|*'dangerously_skip_permissions'*) return 0 ;;
    *'dangerously-bypass-approvals'*|*'dangerously_bypass_approvals'*) return 0 ;;
    *'--sandbox=bypass'*|*'--sandbox bypass'*) return 0 ;;
  esac

  rest="$(printf '%s' "$lowered" | tr ',=' '  ')"
  while [[ -n "$rest" ]]; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [[ -n "$rest" ]] || break
    part="${rest%% *}"
    rest="${rest#"$part"}"
    [[ -n "$part" ]] || continue
    stripped="$part"
    while [[ "$stripped" == -* ]]; do
      stripped="${stripped#-}"
    done
    stripped="${stripped//_/-}"
    case "$stripped" in
      auto|force|yolo|dangerously-skip-permissions|dangerously-bypass-approvals-and-sandbox|dangerously-bypass-approvals|sandbox-bypass|bypass-sandbox|bypass-approvals-and-sandbox|skip-permissions)
        return 0
        ;;
    esac
  done
  return 1
}

# ralph_approval_adapter_reject_dangerous_fallback <value>
# Succeeds when empty or not a banned fallback. Fails closed on the named
# dangerous tokens so they cannot be used as a permission-response path.
ralph_approval_adapter_reject_dangerous_fallback() {
  local raw
  raw="$(ralph_approval_adapter_trim "${1-}")"
  [[ -n "$raw" ]] || return 0
  if ralph_approval_adapter_is_dangerous_fallback "$raw"; then
    echo "Error: approval adapter rejects ${raw} as a permission fallback" >&2
    return 1
  fi
  return 0
}

# ralph_approval_adapter_select_lifetime <requested-lifetime> <proposed> <caps-json>
# Proposed (or requested, when omitted) must be equal or narrower. When
# capabilities are supplied, the chosen lifetime must be supported. An
# omitted proposal may narrow to the broadest supported lifetime that is
# still <= requested. Deny is not a valid narrowing of an allow decision.
ralph_approval_adapter_select_lifetime() {
  local requested="$1" proposed="$2" caps="$3"
  local candidate req_rank cand_rank try try_rank

  candidate="$(ralph_approval_adapter_trim "$proposed")"
  if [[ -z "$candidate" ]]; then
    candidate="$requested"
  fi

  req_rank="$(ralph_approval_adapter_lifetime_rank "$requested")" || {
    echo "Error: approval adapter requested lifetime is unsupported: ${requested:-<empty>}" >&2
    return 1
  }
  cand_rank="$(ralph_approval_adapter_lifetime_rank "$candidate")" || {
    echo "Error: approval adapter native decision is not a known lifetime: ${candidate}" >&2
    return 1
  }
  if [[ "$cand_rank" -gt "$req_rank" ]]; then
    echo "Error: approval adapter native grant is broader than the Ralph request" >&2
    return 1
  fi
  if [[ "$requested" != "deny" && "$candidate" == "deny" ]]; then
    echo "Error: approval adapter native deny cannot satisfy an allow decision" >&2
    return 1
  fi

  if [[ -n "$caps" ]]; then
    if ! ralph_approval_adapter_proof_is_object "$caps"; then
      echo "Error: approval adapter capabilities must be a JSON object" >&2
      return 1
    fi
    if [[ "$candidate" == "deny" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    if ralph_approval_adapter_capability_is_supported "$caps" "lifetime:$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    if [[ -n "$(ralph_approval_adapter_trim "$proposed")" ]]; then
      echo "Error: approval adapter native lifetime is unsupported: $candidate" >&2
      return 1
    fi
    for try in always-policy run once; do
      try_rank="$(ralph_approval_adapter_lifetime_rank "$try")" || continue
      if [[ "$try_rank" -gt "$req_rank" ]]; then
        continue
      fi
      if ralph_approval_adapter_capability_is_supported "$caps" "lifetime:$try"; then
        printf '%s' "$try"
        return 0
      fi
    done
    echo "Error: approval adapter has no equal-or-narrower supported lifetime for $requested" >&2
    return 1
  fi

  printf '%s' "$candidate"
}

# ralph_approval_adapter_translate_decision <translation-json> [capabilities-json]
#
# translation-json:
#   {
#     decision: allow-once|allow-run|allow-always|deny,
#     request?: {action, resource, effect},
#     action?, resource?, effect?,          # used when request is omitted
#     grant? | granted? | nativeGrant?,     # defaults to the request
#     nativeDecision?,                      # once|run|always-policy|deny
#     fallback?                             # rejected when dangerous
#   }
#
# Success prints one compact JSON object:
#   schemaVersion, decision, lifetime, nativeDecision, grant,
#   equalOrNarrower, fallback
# Fail-closed on unknown decisions, broader grants, unsupported broader
# lifetimes, and banned fallbacks.
ralph_approval_adapter_translate_decision() {
  local input="${1-}" caps="${2-}"
  local extracted decision fallback native_in flags args_text
  local req_action req_resource req_effect
  local grant_raw grant_action grant_resource grant_effect
  local requested_lifetime selected_lifetime grant_json fallback_out

  if [[ -z "$input" ]] || ! ralph_approval_adapter_proof_is_object "$input"; then
    echo "Error: approval adapter translation requires a JSON object" >&2
    return 1
  fi

  extracted="$(printf '%s' "$input" | jq -c '
    {
      decision: ((.decision // .choice // "") | tostring),
      fallback: ((.fallback // "") | tostring),
      flags: ((.flags // "") | tostring),
      args: (
        if (.args | type) == "array" then (.args | map(tostring) | join(" "))
        else ((.args // "") | tostring) end
      ),
      nativeDecision: ((.nativeDecision // .native // "") | tostring),
      request: (
        if (.request | type) == "object" then .request
        else {
          action: ((.action // "") | tostring),
          resource: ((.resource // "") | tostring),
          effect: ((.effect // "") | tostring)
        } end
      ),
      grant: (
        if (.grant | type) == "object" then .grant
        elif (.granted | type) == "object" then .granted
        elif (.nativeGrant | type) == "object" then .nativeGrant
        else null end
      )
    }
  ' 2>/dev/null)" || extracted=""
  if [[ -z "$extracted" ]] || ! ralph_approval_adapter_proof_is_object "$extracted"; then
    echo "Error: approval adapter translation requires a JSON object" >&2
    return 1
  fi

  decision="$(printf '%s' "$extracted" | jq -r '.decision')"
  fallback="$(printf '%s' "$extracted" | jq -r '.fallback')"
  flags="$(printf '%s' "$extracted" | jq -r '.flags')"
  args_text="$(printf '%s' "$extracted" | jq -r '.args')"
  native_in="$(printf '%s' "$extracted" | jq -r '.nativeDecision')"
  req_action="$(ralph_approval_adapter_trim "$(printf '%s' "$extracted" | jq -r '.request.action // empty')")"
  req_resource="$(printf '%s' "$extracted" | jq -r '.request.resource // empty')"
  req_effect="$(ralph_approval_adapter_normalize_effect "$(printf '%s' "$extracted" | jq -r '.request.effect // empty')")"
  grant_raw="$(printf '%s' "$extracted" | jq -c '.grant')"

  ralph_approval_adapter_reject_dangerous_fallback "$decision" || return 1
  ralph_approval_adapter_reject_dangerous_fallback "$fallback" || return 1
  ralph_approval_adapter_reject_dangerous_fallback "$flags" || return 1
  ralph_approval_adapter_reject_dangerous_fallback "$args_text" || return 1
  ralph_approval_adapter_reject_dangerous_fallback "$native_in" || return 1

  decision="$(ralph_approval_adapter_trim "$decision")"
  if ! ralph_approval_adapter_token_in_list "$decision" "$RALPH_APPROVAL_ADAPTER_DECISIONS"; then
    echo "Error: approval adapter decision is unsupported: ${decision:-<empty>}" >&2
    return 1
  fi

  requested_lifetime="$(ralph_approval_adapter_decision_to_lifetime "$decision")" || {
    echo "Error: approval adapter decision is unsupported: ${decision}" >&2
    return 1
  }

  if [[ -n "$native_in" ]]; then
    native_in="$(ralph_approval_adapter_trim "$native_in")"
    if ! ralph_approval_adapter_lifetime_rank "$native_in" >/dev/null; then
      echo "Error: approval adapter native decision is not a known lifetime: ${native_in}" >&2
      return 1
    fi
  fi

  selected_lifetime="$(ralph_approval_adapter_select_lifetime "$requested_lifetime" "$native_in" "$caps")" || return 1

  if [[ "$decision" == "deny" ]]; then
    grant_json="null"
  else
    if [[ -z "$req_action" ]]; then
      echo "Error: approval adapter request action must be a non-empty single line" >&2
      return 1
    fi
    req_resource="$(ralph_approval_adapter_normalize_resource "$req_resource")" || return 1
    if ! ralph_approval_adapter_token_in_list "$req_effect" "$RALPH_APPROVAL_ADAPTER_EFFECTS"; then
      echo "Error: approval adapter request effect is unsupported: ${req_effect:-<empty>}" >&2
      return 1
    fi

    if [[ "$grant_raw" == "null" || -z "$grant_raw" ]]; then
      grant_action="$req_action"
      grant_resource="$req_resource"
      grant_effect="$req_effect"
    else
      grant_action="$(ralph_approval_adapter_trim "$(printf '%s' "$grant_raw" | jq -r '.action // empty')")"
      grant_resource="$(printf '%s' "$grant_raw" | jq -r '.resource // empty')"
      grant_effect="$(ralph_approval_adapter_normalize_effect "$(printf '%s' "$grant_raw" | jq -r '.effect // empty')")"
      grant_resource="$(ralph_approval_adapter_normalize_resource "$grant_resource")" || return 1
      if ! ralph_approval_adapter_token_in_list "$grant_effect" "$RALPH_APPROVAL_ADAPTER_EFFECTS"; then
        echo "Error: approval adapter grant effect is unsupported: ${grant_effect:-<empty>}" >&2
        return 1
      fi
    fi

    ralph_approval_adapter_grant_is_exact_or_narrower \
      "$req_action" "$req_resource" "$req_effect" \
      "$grant_action" "$grant_resource" "$grant_effect" || return 1

    grant_json="$(jq -nc \
      --arg action "$grant_action" \
      --arg resource "$grant_resource" \
      --arg effect "$grant_effect" \
      '{action:$action,resource:$resource,effect:$effect}')"
  fi

  fallback_out="$(ralph_approval_adapter_trim "$fallback")"
  jq -nc \
    --argjson schema "$RALPH_APPROVAL_ADAPTER_SCHEMA_VERSION" \
    --arg decision "$decision" \
    --arg lifetime "$selected_lifetime" \
    --argjson grant "$grant_json" \
    --arg fallback "$fallback_out" \
    '{
      schemaVersion: $schema,
      decision: $decision,
      lifetime: $lifetime,
      nativeDecision: $lifetime,
      grant: $grant,
      equalOrNarrower: true,
      fallback: (if $fallback == "" then null else $fallback end)
    }'
}

# ralph_approval_adapter_ensure_overlay_lib
# Source the shared runtime overlay helper once. Overlay state is not
# initialized here.
ralph_approval_adapter_ensure_overlay_lib() {
  if declare -F runtime_overlay_record_original_file >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=/dev/null
  source "$_RALPH_APPROVAL_ADAPTER_DIR/../runtime-overlay/runtime-overlay.sh"
}

# ralph_approval_adapter_ensure_overlay_state <runtime>
ralph_approval_adapter_ensure_overlay_state() {
  local runtime="$1" plan_key="${RALPH_PLAN_KEY:-}"
  ralph_approval_adapter_ensure_overlay_lib || return 1
  if [[ -n "${RUNTIME_OVERLAY_STATE_DIR:-}" ]]; then
    return 0
  fi
  if [[ -z "$plan_key" ]]; then
    echo "Error: approval adapter overlay fallback requires RALPH_PLAN_KEY" >&2
    return 1
  fi
  runtime_overlay_init_state "$runtime" "$plan_key"
}

# ralph_approval_adapter_is_ambient_user_path <path>
# True for runtime-global homes that must never receive a fallback overlay.
ralph_approval_adapter_is_ambient_user_path() {
  local abs="$1" home="${HOME:-}"
  [[ -n "$abs" && -n "$home" ]] || return 1
  case "$abs" in
    "$home/.claude"|"$home/.claude"/*|"$home/.cursor"|"$home/.cursor"/*|"$home/.codex"|"$home/.codex"/*|"$home/.opencode"|"$home/.opencode"/*|"$home/.agents"|"$home/.agents"/*)
      return 0
      ;;
  esac
  return 1
}

# ralph_approval_adapter_select_continuation <decision> [capabilities-json]
# deny or missing sessionContinuation -> compact. Known session
# continuation -> session. Compact is limited to one turn per overlay cycle.
ralph_approval_adapter_select_continuation() {
  local decision="$1" caps="${2-}"
  decision="$(ralph_approval_adapter_trim "$decision")"
  if [[ "$decision" == "deny" ]]; then
    printf 'compact'
    return 0
  fi
  if [[ -n "$caps" ]] && ralph_approval_adapter_capability_is_supported "$caps" sessionContinuation; then
    printf 'session'
    return 0
  fi
  printf 'compact'
}

# ralph_approval_adapter_overlay_state_path
# Run-local state file so apply/restore survive command-substitution subshells.
ralph_approval_adapter_overlay_state_path() {
  local plan_key="${RALPH_PLAN_KEY:-}" state_dir
  ralph_approval_adapter_ensure_overlay_lib || return 1
  if [[ -n "${RUNTIME_OVERLAY_STATE_DIR:-}" ]]; then
    printf '%s/approval-overlay-state.json' "$RUNTIME_OVERLAY_STATE_DIR"
    return 0
  fi
  [[ -n "$plan_key" ]] || return 1
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    state_dir="$(_runtime_overlay_workspace_root)/runtime-config/${plan_key}"
  else
    state_dir="$(_runtime_overlay_project_root)/.ralph-workspace/runtime-config/${plan_key}"
  fi
  printf '%s/approval-overlay-state.json' "$state_dir"
}

# ralph_approval_adapter_overlay_load_state
# Load persisted overlay entries into the in-memory arrays.
ralph_approval_adapter_overlay_load_state() {
  local state_path n i
  RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS=()
  RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS=()
  RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED=()
  RALPH_APPROVAL_ADAPTER_COMPACT_TURN_USED=0
  state_path="$(ralph_approval_adapter_overlay_state_path 2>/dev/null || true)"
  [[ -n "$state_path" && -f "$state_path" ]] || return 0
  n="$(jq -r '.entries | length' "$state_path" 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  for ((i=0; i<n; i++)); do
    RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS+=("$(jq -r --argjson i "$i" '.entries[$i].path // empty' "$state_path")")
    RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS+=("$(jq -r --argjson i "$i" '.entries[$i].backup // empty' "$state_path")")
    RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED+=("$(jq -r --argjson i "$i" '.entries[$i].existed // 0' "$state_path")")
  done
  if [[ "$(jq -r '.compactTurnUsed // false' "$state_path")" == "true" ]]; then
    RALPH_APPROVAL_ADAPTER_COMPACT_TURN_USED=1
  fi
}

# ralph_approval_adapter_overlay_save_state
ralph_approval_adapter_overlay_save_state() {
  local state_path idx compact="false" entries="[]" entry
  state_path="$(ralph_approval_adapter_overlay_state_path)" || return 1
  mkdir -p "$(dirname "$state_path")"
  if [[ "${RALPH_APPROVAL_ADAPTER_COMPACT_TURN_USED:-0}" == "1" ]]; then
    compact="true"
  fi
  entries="[]"
  for ((idx=0; idx<${#RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS[@]}; idx++)); do
    entry="$(jq -nc \
      --arg path "${RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS[idx]}" \
      --arg backup "${RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS[idx]:-}" \
      --argjson existed "${RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED[idx]:-0}" \
      '{path:$path,backup:$backup,existed:$existed}')" || return 1
    entries="$(jq -nc --argjson acc "$entries" --argjson ent "$entry" '$acc + [$ent]')" || return 1
  done
  jq -nc \
    --argjson schema "$RALPH_APPROVAL_ADAPTER_SCHEMA_VERSION" \
    --argjson compact "$compact" \
    --argjson entries "$entries" \
    '{schemaVersion:$schema,compactTurnUsed:$compact,entries:$entries}' >"$state_path"
}

# ralph_approval_adapter_overlay_reset
ralph_approval_adapter_overlay_reset() {
  local state_path
  RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS=()
  RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS=()
  RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED=()
  RALPH_APPROVAL_ADAPTER_COMPACT_TURN_USED=0
  RALPH_APPROVAL_ADAPTER_OVERLAY_TRAPS=0
  state_path="$(ralph_approval_adapter_overlay_state_path 2>/dev/null || true)"
  if [[ -n "$state_path" && -f "$state_path" ]]; then
    rm -f "$state_path"
  fi
}

# ralph_approval_adapter_overlay_restore [reason]
# Restore every overlay this adapter applied. Reasons: success, denial,
# failure, timeout, signal. Always restores; unknown reasons still clean up.
# State is file-backed so restore works after apply ran in a subshell.
ralph_approval_adapter_overlay_restore() {
  local reason="${1:-success}" idx target backup existed
  case "$reason" in
    success|denial|failure|timeout|signal) ;;
    *) reason="failure" ;;
  esac
  ralph_approval_adapter_ensure_overlay_lib || true
  ralph_approval_adapter_overlay_load_state || true
  if [[ ${#RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS[@]} -gt 0 ]]; then
    for ((idx=${#RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS[@]}-1; idx>=0; idx--)); do
      target="${RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS[idx]}"
      backup="${RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS[idx]:-}"
      existed="${RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED[idx]:-0}"
      if declare -F runtime_overlay_restore_file >/dev/null 2>&1; then
        runtime_overlay_restore_file "$target" "$backup" "$existed" || true
      elif [[ "$existed" == "1" && -n "$backup" && -f "$backup" ]]; then
        mkdir -p "$(dirname "$target")"
        cp "$backup" "$target" 2>/dev/null || true
      else
        rm -f "$target" 2>/dev/null || true
      fi
    done
  fi
  ralph_approval_adapter_overlay_reset
  jq -nc \
    --argjson schema "$RALPH_APPROVAL_ADAPTER_SCHEMA_VERSION" \
    --arg reason "$reason" \
    '{schemaVersion:$schema,restored:true,reason:$reason}'
}

# ralph_approval_adapter_overlay_signal_handler [INT|TERM|HUP]
ralph_approval_adapter_overlay_signal_handler() {
  local sig="${1:-TERM}"
  ralph_approval_adapter_overlay_restore signal >/dev/null || true
  trap - INT TERM HUP
  kill -s "$sig" "$$" 2>/dev/null || exit 143
}

# ralph_approval_adapter_overlay_install_traps
# Restore adapter overlays on INT/TERM/HUP. Chains over existing traps.
ralph_approval_adapter_overlay_install_traps() {
  local sig existing
  if [[ "${RALPH_APPROVAL_ADAPTER_OVERLAY_TRAPS:-0}" == "1" ]]; then
    return 0
  fi
  RALPH_APPROVAL_ADAPTER_OVERLAY_TRAPS=1
  for sig in INT TERM HUP; do
    existing="$(trap -p "$sig" 2>/dev/null || true)"
    if [[ -n "$existing" && "$existing" != "trap -- '' $sig" && "$existing" != "trap -- \"\" $sig" ]]; then
      existing="${existing#trap -- \'}"
      existing="${existing#trap -- \"}"
      existing="${existing%\' $sig}"
      existing="${existing%\" $sig}"
      # shellcheck disable=SC2064
      trap "ralph_approval_adapter_overlay_signal_handler $sig; $existing" "$sig"
    else
      # shellcheck disable=SC2064
      trap "ralph_approval_adapter_overlay_signal_handler $sig" "$sig"
    fi
  done
}

# ralph_approval_adapter_overlay_fallback <request-json> [capabilities-json]
#
# Apply a run-local reversible overlay when the grant is expressible, then
# resume the same session or make one compact continuation turn.
#
# request-json:
#   decision, request/action/resource/effect, grant?, runtime?,
#   target?, overlay?, sessionId?, fallback?
#
# Deny does not write an overlay. Dangerous fallbacks are rejected.
# Ambient user-global paths are rejected. Restore on every terminal path
# through ralph_approval_adapter_overlay_restore.
ralph_approval_adapter_overlay_fallback() {
  local input="${1-}" caps="${2-}"
  local translated decision lifetime grant_json fallback_out
  local runtime target overlay_raw overlay_text session_id
  local backup="" existed=0 applied=false
  local continuation session_strategy compact_used
  local tmp_path supplied_caps="$caps"

  if [[ -z "$input" ]] || ! ralph_approval_adapter_proof_is_object "$input"; then
    echo "Error: approval adapter overlay fallback requires a JSON object" >&2
    return 1
  fi

  runtime="$(ralph_approval_adapter_normalize_runtime "$(printf '%s' "$input" | jq -r '.runtime // empty')")"
  if [[ -z "$caps" ]]; then
    caps="$(ralph_approval_adapter_capabilities "$runtime")"
  fi

  translated="$(ralph_approval_adapter_translate_decision "$input" "$supplied_caps")" || return 1
  decision="$(printf '%s' "$translated" | jq -r '.decision')"
  lifetime="$(printf '%s' "$translated" | jq -r '.lifetime')"
  grant_json="$(printf '%s' "$translated" | jq -c '.grant')"
  fallback_out="$(printf '%s' "$translated" | jq -r '.fallback // empty')"

  session_id="$(ralph_approval_adapter_trim "$(printf '%s' "$input" | jq -r '.sessionId // .session_id // empty')")"
  target="$(ralph_approval_adapter_trim "$(printf '%s' "$input" | jq -r '.target // empty')")"
  overlay_raw="$(printf '%s' "$input" | jq -c '.overlay // empty')"

  ralph_approval_adapter_overlay_load_state || true
  continuation="$(ralph_approval_adapter_select_continuation "$decision" "$caps")"
  if [[ "$continuation" == "compact" ]]; then
    compact_used="${RALPH_APPROVAL_ADAPTER_COMPACT_TURN_USED:-0}"
    if [[ "$compact_used" == "1" ]]; then
      echo "Error: approval adapter overlay fallback allows only one compact continuation turn" >&2
      return 1
    fi
    session_strategy="compact"
  else
    session_strategy="resume"
  fi

  if [[ "$decision" != "deny" ]]; then
    ralph_approval_adapter_ensure_overlay_state "$runtime" || return 1
    if [[ -z "$target" ]]; then
      target="$(runtime_overlay_state_dir)/approval-overlay.json"
    fi
    if declare -F _runtime_overlay_abs_path >/dev/null 2>&1; then
      target="$(_runtime_overlay_abs_path "$target")"
    fi
    if ralph_approval_adapter_is_ambient_user_path "$target"; then
      echo "Error: approval adapter overlay fallback refuses ambient user path: $target" >&2
      return 1
    fi
    if [[ -z "$overlay_raw" || "$overlay_raw" == "null" || "$overlay_raw" == '""' ]]; then
      overlay_text="$(jq -nc \
        --argjson schema "$RALPH_APPROVAL_ADAPTER_SCHEMA_VERSION" \
        --arg lifetime "$lifetime" \
        --argjson grant "$grant_json" \
        '{schemaVersion:$schema,kind:"ralph-approval-overlay",lifetime:$lifetime,grant:$grant}')"
    else
      if printf '%s' "$overlay_raw" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
        overlay_text="$overlay_raw"
      else
        overlay_text="$(printf '%s' "$overlay_raw" | jq -r 'if type == "string" then . else empty end')"
        if [[ -z "$overlay_text" ]] || ! printf '%s' "$overlay_text" | jq -e '.' >/dev/null 2>&1; then
          echo "Error: approval adapter overlay fallback overlay must be JSON" >&2
          return 1
        fi
      fi
      ralph_approval_adapter_reject_dangerous_fallback "$overlay_text" || return 1
    fi

    if [[ -f "$target" ]]; then
      existed=1
    fi
    runtime_overlay_record_original_file "$target" "" 1 || return 1
    if [[ ${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]} -gt 0 ]]; then
      backup="${RUNTIME_OVERLAY_MUTATED_BACKUPS[${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]}-1]}"
    fi
    mkdir -p "$(dirname "$target")"
    tmp_path="${target}.ralph-approval.tmp"
    if ! printf '%s\n' "$overlay_text" >"$tmp_path"; then
      runtime_overlay_restore_file "$target" "$backup" "$existed" || true
      echo "Error: approval adapter overlay fallback failed to write $target" >&2
      return 1
    fi
    mv "$tmp_path" "$target"
    RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS+=("$target")
    RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS+=("$backup")
    RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED+=("$existed")
    applied=true
    ralph_approval_adapter_overlay_install_traps
  fi

  if [[ "$continuation" == "compact" ]]; then
    RALPH_APPROVAL_ADAPTER_COMPACT_TURN_USED=1
  fi
  ralph_approval_adapter_overlay_save_state || true

  jq -nc \
    --argjson schema "$RALPH_APPROVAL_ADAPTER_SCHEMA_VERSION" \
    --arg decision "$decision" \
    --arg lifetime "$lifetime" \
    --argjson grant "$grant_json" \
    --arg fallback "$fallback_out" \
    --arg continuation "$continuation" \
    --arg sessionStrategy "$session_strategy" \
    --arg sessionId "$session_id" \
    --arg target "$target" \
    --arg backup "$backup" \
    --argjson applied "$applied" \
    '{
      schemaVersion: $schema,
      fallback: "overlay",
      applied: $applied,
      decision: $decision,
      lifetime: $lifetime,
      grant: $grant,
      equalOrNarrower: true,
      continuation: $continuation,
      sessionStrategy: $sessionStrategy,
      sessionId: (if $sessionId == "" then null else $sessionId end),
      target: (if $applied then $target else null end),
      backup: (if $applied and $backup != "" then $backup else null end),
      restored: false,
      compactTurns: (if $continuation == "compact" then 1 else 0 end),
      fallbackName: (if $fallback == "" then "overlay" else $fallback end)
    }'
}

# ---------------------------------------------------------------------------
# G16 approval continuation transaction
# ---------------------------------------------------------------------------
#
# Before retry the adapter either answers the original native request
# (same-operation) or installs a journaled narrow overlay. allow-once is
# consumed atomically when that continuation begins. The same normalized
# tuple must not immediately recreate itself while an allow-once continuation
# is active; that is an adapter defect, not a fresh operator prompt.
# Unsupported lifetimes never appear in choices. Deny remains stronger and
# does not write an allow overlay.

# ralph_approval_adapter_iso_now
ralph_approval_adapter_iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ralph_approval_adapter_continuation_root
# Run-local directory for continuation / consume / active-tuple state.
ralph_approval_adapter_continuation_root() {
  local plan_key="${RALPH_PLAN_KEY:-}" state_dir
  ralph_approval_adapter_ensure_overlay_lib || return 1
  if [[ -n "${RUNTIME_OVERLAY_STATE_DIR:-}" ]]; then
    printf '%s/approval-continuation' "$RUNTIME_OVERLAY_STATE_DIR"
    return 0
  fi
  [[ -n "$plan_key" ]] || return 1
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    state_dir="$(_runtime_overlay_workspace_root)/runtime-config/${plan_key}"
  else
    state_dir="$(_runtime_overlay_project_root)/.ralph-workspace/runtime-config/${plan_key}"
  fi
  printf '%s/approval-continuation' "$state_dir"
}

# ralph_approval_adapter_normalized_tuple <request-json>
# Exact normalized identity for create-once binding.
ralph_approval_adapter_normalized_tuple() {
  local input="${1:-}"
  if [[ -z "$input" ]] || ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval adapter normalized tuple requires a JSON object" >&2
    return 1
  fi
  printf '%s' "$input" | jq -c '
    def str($v):
      if $v == null then ""
      elif ($v | type) == "string" then $v
      elif ($v | type) == "number" then ($v | tostring)
      else "" end;
    {
      runtime: (str(.runtime // "") | ascii_downcase),
      tool: str(.tool // .request.tool // .grant.tool // ""),
      action: str(.action // .request.action // .grant.action // ""),
      resource: str(.resource // .request.resource // .grant.resource // ""),
      effect: str(.effect // .request.effect // .grant.effect // ""),
      sessionId: str(.sessionId // .session_id // .session // ""),
      nativeRequestId: str(.nativeRequestId // .requestId // .id // "")
    }
  '
}

# ralph_approval_adapter_can_enforce_once <capabilities-json>
# allow-once requires same-operation response or the tested overlay fallback
# (lifetime:once proved, or no explicit once:false veto).
ralph_approval_adapter_can_enforce_once() {
  local caps="${1:-}"
  if [[ -z "$caps" ]] || ! printf '%s' "$caps" | jq -e 'type == "object"' >/dev/null 2>&1; then
    return 0
  fi
  if ralph_approval_adapter_capability_is_supported "$caps" sameOperationResponse; then
    return 0
  fi
  if ralph_approval_adapter_capability_is_supported "$caps" "lifetime:once"; then
    return 0
  fi
  # Explicit once:false without same-operation means allow-once must not be offered.
  if printf '%s' "$caps" | jq -e '(.lifetimes | type) == "object" and .lifetimes.once == false' >/dev/null 2>&1; then
    return 1
  fi
  # Overlay fallback remains the tested narrow continuation path.
  return 0
}

# ralph_approval_adapter_active_continuation_path
ralph_approval_adapter_active_continuation_path() {
  local root
  root="$(ralph_approval_adapter_continuation_root)" || return 1
  printf '%s/active.json' "$root"
}

# ralph_approval_adapter_continuation_record_path <request-id>
ralph_approval_adapter_continuation_record_path() {
  local request_id="${1:-}" root
  [[ -n "$request_id" ]] || return 1
  root="$(ralph_approval_adapter_continuation_root)" || return 1
  printf '%s/continuations/%s.json' "$root" "$request_id"
}

# ralph_approval_adapter_consume_record_path <request-id>
ralph_approval_adapter_consume_record_path() {
  local request_id="${1:-}" root
  [[ -n "$request_id" ]] || return 1
  root="$(ralph_approval_adapter_continuation_root)" || return 1
  printf '%s/consumed/%s.json' "$root" "$request_id"
}

# ralph_approval_adapter_clear_active_continuation
ralph_approval_adapter_clear_active_continuation() {
  local path
  path="$(ralph_approval_adapter_active_continuation_path 2>/dev/null || true)"
  [[ -n "$path" && -f "$path" ]] || return 0
  rm -f "$path"
}

# ralph_approval_adapter_assert_not_recreated <request-json>
# Fail as adapter-defect when an active allow-once continuation covers the
# same normalized tuple and the new request id differs (immediate recreation).
ralph_approval_adapter_assert_not_recreated() {
  local input="${1:-}" active_path active tuple request_id active_id
  local tool action resource effect runtime

  active_path="$(ralph_approval_adapter_active_continuation_path 2>/dev/null || true)"
  [[ -n "$active_path" && -f "$active_path" ]] || return 0

  tuple="$(ralph_approval_adapter_normalized_tuple "$input")" || return 1
  request_id="$(printf '%s' "$tuple" | jq -r '.nativeRequestId // empty')"
  runtime="$(printf '%s' "$tuple" | jq -r '.runtime // empty')"
  tool="$(printf '%s' "$tuple" | jq -r '.tool // empty')"
  action="$(printf '%s' "$tuple" | jq -r '.action // empty')"
  resource="$(printf '%s' "$tuple" | jq -r '.resource // empty')"
  effect="$(printf '%s' "$tuple" | jq -r '.effect // empty')"

  active="$(cat "$active_path")"
  active_id="$(printf '%s' "$active" | jq -r '.nativeRequestId // empty')"
  if [[ "$(printf '%s' "$active" | jq -r '.decision // empty')" != "allow-once" ]]; then
    return 0
  fi
  if [[ "$request_id" == "$active_id" ]]; then
    echo "Error: approval adapter continuation defect: same request recreated after consume ($request_id)" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$active" | jq -r '.tuple.runtime // empty')" == "$runtime" \
        && "$(printf '%s' "$active" | jq -r '.tuple.tool // empty')" == "$tool" \
        && "$(printf '%s' "$active" | jq -r '.tuple.action // empty')" == "$action" \
        && "$(printf '%s' "$active" | jq -r '.tuple.resource // empty')" == "$resource" \
        && "$(printf '%s' "$active" | jq -r '.tuple.effect // empty')" == "$effect" ]]; then
    echo "Error: approval adapter continuation defect: normalized tuple recreated after allow-once ($active_id -> $request_id)" >&2
    return 1
  fi
  return 0
}

# ralph_approval_adapter_write_consume_record <request-json> <decision> <path-kind>
# Create-once consume record. Second write of the same request id fails.
ralph_approval_adapter_write_consume_record() {
  local input="${1:-}" decision="${2:-}" path_kind="${3:-adapter-continuation}"
  local tuple request_id path tmp root

  tuple="$(ralph_approval_adapter_normalized_tuple "$input")" || return 1
  request_id="$(printf '%s' "$tuple" | jq -r '.nativeRequestId // empty')"
  if [[ -z "$request_id" ]]; then
    echo "Error: approval adapter consume requires nativeRequestId" >&2
    return 1
  fi
  path="$(ralph_approval_adapter_consume_record_path "$request_id")" || return 1
  if [[ -f "$path" ]]; then
    echo "Error: approval adapter decision already consumed: $request_id" >&2
    return 1
  fi
  root="$(dirname "$path")"
  mkdir -p "$root" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-approval-consume.XXXXXX")" || return 1
  jq -nc \
    --argjson tuple "$tuple" \
    --arg decision "$decision" \
    --arg path_kind "$path_kind" \
    --arg consumedAt "$(ralph_approval_adapter_iso_now)" \
    --arg requestId "$request_id" \
    '{
      schemaVersion: 1,
      requestId: $requestId,
      decision: $decision,
      path: $path_kind,
      consumedAt: $consumedAt,
      tuple: $tuple
    }' >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! ln "$tmp" "$path" 2>/dev/null; then
    if [[ -f "$path" ]]; then
      rm -f "$tmp"
      echo "Error: approval adapter decision already consumed: $request_id" >&2
      return 1
    fi
    mv "$tmp" "$path" || {
      rm -f "$tmp"
      return 1
    }
  else
    rm -f "$tmp"
  fi
  printf '%s\n' "$path"
}

# ralph_approval_adapter_write_continuation_record <request-json> <decision> <path-kind> <applied-json>
ralph_approval_adapter_write_continuation_record() {
  local input="${1:-}" decision="${2:-}" path_kind="${3:-overlay}"
  local applied="${4:-"{}"}"
  local tuple request_id path root tmp_applied

  tuple="$(ralph_approval_adapter_normalized_tuple "$input")" || return 1
  request_id="$(printf '%s' "$tuple" | jq -r '.nativeRequestId // empty')"
  if [[ -z "$request_id" ]]; then
    echo "Error: approval adapter continuation requires nativeRequestId" >&2
    return 1
  fi
  path="$(ralph_approval_adapter_continuation_record_path "$request_id")" || return 1
  root="$(dirname "$path")"
  mkdir -p "$root" || return 1
  tmp_applied="$(mktemp "${TMPDIR:-/tmp}/ralph-approval-applied.XXXXXX")" || return 1
  if ! printf '%s' "$applied" | jq -c '.' >"$tmp_applied" 2>/dev/null; then
    rm -f "$tmp_applied"
    echo "Error: approval adapter continuation applied payload must be JSON" >&2
    return 1
  fi
  jq -nc \
    --argjson tuple "$tuple" \
    --slurpfile applied "$tmp_applied" \
    --arg decision "$decision" \
    --arg path_kind "$path_kind" \
    --arg requestId "$request_id" \
    --arg at "$(ralph_approval_adapter_iso_now)" \
    '{
      schemaVersion: 1,
      requestId: $requestId,
      decision: $decision,
      path: $path_kind,
      createdAt: $at,
      tuple: $tuple,
      applied: $applied[0]
    }' >"$path" || {
    rm -f "$tmp_applied"
    return 1
  }
  rm -f "$tmp_applied"
  printf '%s\n' "$path"
}

# ralph_approval_adapter_set_active_continuation <request-json> <decision> <path-kind>
ralph_approval_adapter_set_active_continuation() {
  local input="${1:-}" decision="${2:-}" path_kind="${3:-overlay}"
  local tuple request_id path root

  tuple="$(ralph_approval_adapter_normalized_tuple "$input")" || return 1
  request_id="$(printf '%s' "$tuple" | jq -r '.nativeRequestId // empty')"
  path="$(ralph_approval_adapter_active_continuation_path)" || return 1
  root="$(dirname "$path")"
  mkdir -p "$root" || return 1
  jq -nc \
    --argjson tuple "$tuple" \
    --arg decision "$decision" \
    --arg path_kind "$path_kind" \
    --arg requestId "$request_id" \
    --arg at "$(ralph_approval_adapter_iso_now)" \
    '{
      schemaVersion: 1,
      nativeRequestId: $requestId,
      decision: $decision,
      path: $path_kind,
      startedAt: $at,
      tuple: $tuple
    }' >"$path" || return 1
}

# ralph_approval_adapter_continue <request-json> [capabilities-json]
#
# G16 transaction. request-json fields:
#   decision, runtime, tool?, action, resource, effect, sessionId,
#   nativeRequestId|requestId, target?, overlay?, sameOperationReply?
#     (bool: caller already answered the live native request)
#
# allow-once: same-operation reply OR journaled narrow overlay before retry.
# If neither is possible, refuse (do not offer allow-once).
# Consumes allow-once atomically when continuation begins.
# Prints one compact JSON object with continuation + consume paths.
ralph_approval_adapter_continue() {
  local input="${1:-}" caps="${2:-}"
  local decision lifetime translated applied path_kind
  local consume_path continuation_path session_id request_id
  local same_op_done overlay_input runtime tmp_applied

  if [[ -z "$input" ]] || ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: approval adapter continue requires a JSON object" >&2
    return 1
  fi
  ralph_approval_adapter_assert_not_recreated "$input" || return 1

  decision="$(ralph_approval_adapter_trim "$(printf '%s' "$input" | jq -r '.decision // empty')")"
  runtime="$(ralph_approval_adapter_normalize_runtime "$(printf '%s' "$input" | jq -r '.runtime // empty')")"
  session_id="$(printf '%s' "$input" | jq -r '.sessionId // .session_id // .session // empty')"
  request_id="$(printf '%s' "$input" | jq -r '.nativeRequestId // .requestId // .id // empty')"
  same_op_done="$(printf '%s' "$input" | jq -r '(.sameOperationReply // false) | tostring')"

  if [[ -z "$caps" ]] || ! printf '%s' "$caps" | jq -e 'type == "object"' >/dev/null 2>&1; then
    caps="$(ralph_approval_adapter_capabilities "$runtime")"
  fi

  if [[ "$decision" == "allow-once" ]]; then
    if ! ralph_approval_adapter_can_enforce_once "$caps"; then
      echo "Error: approval adapter cannot enforce allow-once (no same-operation response or overlay); do not offer it" >&2
      return 1
    fi
    if [[ "$same_op_done" != "true" ]] \
         && ! ralph_approval_adapter_capability_is_supported "$caps" sameOperationResponse \
         && [[ "$(printf '%s' "$input" | jq -r '.overlay // .target // empty')" == "" ]] \
         && [[ "$(printf '%s' "$input" | jq -c '.overlay // null')" == "null" ]]; then
      # Overlay fallback can still synthesize a narrow grant from action/resource.
      :
    fi
  fi

  translated="$(ralph_approval_adapter_translate_decision "$input" "$caps")" || return 1
  lifetime="$(printf '%s' "$translated" | jq -r '.lifetime')"
  decision="$(printf '%s' "$translated" | jq -r '.decision')"

  if [[ "$decision" == "allow-once" && "$same_op_done" == "true" ]]; then
    path_kind="same-operation"
    applied="$(jq -nc \
      --argjson translated "$translated" \
      --arg runtime "$runtime" \
      --arg session "$session_id" \
      '{
        schemaVersion: 1,
        runtime: $runtime,
        path: "same-operation",
        fallback: "same-operation",
        applied: true,
        decision: $translated.decision,
        lifetime: $translated.lifetime,
        grant: $translated.grant,
        equalOrNarrower: true,
        continuation: "session",
        sessionStrategy: "resume",
        sessionId: (if $session == "" then null else $session end),
        target: null,
        backup: null,
        restored: false,
        compactTurns: 0
      }')"
  else
    path_kind="overlay"
    if [[ "$decision" == "deny" ]]; then
      path_kind="deny"
    fi
    overlay_input="$(printf '%s' "$input" | jq -c \
      --argjson translated "$translated" \
      --arg runtime "$runtime" \
      --arg session "$session_id" \
      '{
        decision: $translated.decision,
        runtime: $runtime,
        action: ($translated.grant.action // .action // .request.action // ""),
        resource: ($translated.grant.resource // .resource // .request.resource // ""),
        effect: ($translated.grant.effect // .effect // .request.effect // ""),
        grant: $translated.grant,
        sessionId: $session
      }
      + (if (.target | type) == "string" and .target != "" then {target:.target} else {} end)
      + (if (.overlay != null) then {overlay:.overlay} else {} end)')"
    applied="$(ralph_approval_adapter_overlay_fallback "$overlay_input" "$caps")" || return 1
  fi

  # Atomic consume when the continued operation begins (allow-* only).
  consume_path=""
  if [[ "$decision" == "allow-once" || "$decision" == "allow-run" || "$decision" == "allow-always" ]]; then
    consume_path="$(ralph_approval_adapter_write_consume_record "$input" "$decision" "$path_kind")" || return 1
    ralph_approval_adapter_set_active_continuation "$input" "$decision" "$path_kind" || return 1
  fi

  continuation_path="$(ralph_approval_adapter_write_continuation_record \
    "$input" "$decision" "$path_kind" "$applied")" || return 1

  tmp_applied="$(mktemp "${TMPDIR:-/tmp}/ralph-approval-continue-applied.XXXXXX")" || return 1
  printf '%s' "$applied" >"$tmp_applied"
  jq -nc \
    --slurpfile applied_file "$tmp_applied" \
    --arg consume "${consume_path:-}" \
    --arg continuation "$continuation_path" \
    --arg path_kind "$path_kind" \
    --arg decision "$decision" \
    --arg lifetime "$lifetime" \
    --arg requestId "$request_id" \
    '{
      schemaVersion: 1,
      decision: $decision,
      lifetime: $lifetime,
      path: $path_kind,
      requestId: (if $requestId == "" then null else $requestId end),
      consumeRecord: (if $consume == "" then null else $consume end),
      continuationRecord: $continuation,
      applied: $applied_file[0],
      continuation: $applied_file[0].continuation,
      sessionStrategy: $applied_file[0].sessionStrategy,
      sessionId: $applied_file[0].sessionId,
      target: $applied_file[0].target,
      backup: $applied_file[0].backup,
      restored: false
    }'
  rm -f "$tmp_applied"
}

# ralph_approval_adapter_continue_restore [reason]
# Clears the active continuation tuple and restores journaled overlays.
ralph_approval_adapter_continue_restore() {
  local reason="${1:-success}" restored
  restored="$(ralph_approval_adapter_overlay_restore "$reason")" || true
  ralph_approval_adapter_clear_active_continuation
  if [[ -n "$restored" ]]; then
    printf '%s\n' "$restored"
  else
    jq -nc --arg reason "$reason" '{schemaVersion:1,restored:true,reason:$reason}'
  fi
}
