#!/usr/bin/env bash
# Jev policy helpers. Source only.
#
# This is where Ralph, not Jev, makes act/gather/fallback decisions.
#
# HARD GUARD: Thresholds come ONLY from the question-set registry
# (RALPH_JEV_REGISTRY). Callers must never pass their own act/escalate
# thresholds. jev_policy_threshold and jev_policy_decide read policy.actThreshold
# and policy.escalateThreshold from the registered set only.
#
# Public interface:
#   jev_policy_questions <question_set_id>
#       -> stdout that set's questions object. 0 | 1 (unknown id: silent 1)
#   jev_policy_threshold <question_set_id> <act|escalate>
#       -> stdout numeric threshold from that set's policy. 0 | 1
#   jev_policy_decide <question_set_id> <answers_json>
#       -> stdout decision JSON (Section E). 0 | 1
#       When RALPH_JEV_SHADOW=1: still computes and records the would-have
#       decision (shadow=true on the record), but returns decision=fallback.
#   jev_shadow_report [decisions.jsonl]
#       -> stdout calibration report per surface x questionSetId. 0 | 1
#       Requires python3. Default path: <RALPH_JEV_STATE_DIR>/decisions.jsonl.
#
# Decision rule (primaryQuestion answer):
#   confidence = .confidence for choice/score; for noul use .noul (no confidence field)
#   confidence >= actThreshold                         -> act
#   escalateThreshold <= confidence < actThreshold     -> gather
#   confidence < escalateThreshold                     -> fallback
# Choice key absent from non-empty criteria            -> fallback / option-not-offered

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${RALPH_JEV_POLICY_LOADED:-}" ]]; then
  return 0
fi
RALPH_JEV_POLICY_LOADED=1

_JEV_POLICY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_JEV_SHADOW_REPORT_PY="${_JEV_POLICY_LIB_DIR}/../../python/jev_shadow_report.py"

# Resolve RALPH_JEV_STATE_DIR the same way jev-client.sh does.
_jev_policy_state_dir() {
  if [[ -n "${RALPH_JEV_STATE_DIR:-}" ]]; then
    printf '%s\n' "${RALPH_JEV_STATE_DIR%/}"
    return 0
  fi
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$PWD/.ralph-workspace}"
  printf '%s/jev\n' "${state_root%/}"
}

# Ensure jev_record_decision is available for shadow telemetry (best-effort).
_jev_policy_ensure_record_decision() {
  if declare -F jev_record_decision >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=./jev-client.sh
  source "$_JEV_POLICY_LIB_DIR/jev-client.sh" 2>/dev/null || return 1
  declare -F jev_record_decision >/dev/null 2>&1
}

# Write a shadow decision record with the would-have decision. Never fails the caller.
_jev_policy_shadow_record() {
  local decision_json="${1:-}"
  local set_json="${2:-}"
  local answers_json="${3:-}"
  local record dir

  [[ -n "$decision_json" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  # Do not use ${var:-{}} — bash treats the closing } as end of expansion and
  # leaves a literal }, which corrupts --argjson payloads.
  [[ -n "$set_json" ]] || set_json='{}'
  [[ -n "$answers_json" ]] || answers_json='{}'

  record="$(
    jq -nc \
      --argjson d "$decision_json" \
      --argjson set "$set_json" \
      --argjson answers "$answers_json" \
      '
      $d + {
        surface: ($set.surface // ($d.surface // "")),
        answers: (if ($answers | type) == "object" then $answers else {} end),
        shadow: true,
        fallbackUsed: true,
        registryVersion: "1"
      }
      ' 2>/dev/null
  )" || record=""
  [[ -n "$record" ]] || return 0

  if _jev_policy_ensure_record_decision && jev_record_decision "$record" >/dev/null 2>&1; then
    return 0
  fi

  # Fallback append when the client recorder is unavailable or failed.
  dir="$(_jev_policy_state_dir)" || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  if declare -F jev_redact_secrets_inline >/dev/null 2>&1; then
    record="$(jev_redact_secrets_inline "$record" 2>/dev/null)" || return 0
    record="${record%$'\n'}"
  fi
  [[ -n "$record" ]] || return 0
  printf '%s\n' "$record" >>"${dir}/decisions.jsonl" 2>/dev/null || true
  return 0
}

# Resolve the registry path. Default: <RALPH_DIR>/jev/questions.registry.json
_jev_policy_registry_path() {
  if [[ -n "${RALPH_JEV_REGISTRY:-}" ]]; then
    printf '%s\n' "$RALPH_JEV_REGISTRY"
    return 0
  fi
  local ralph_dir
  if [[ -n "${RALPH_DIR:-}" ]]; then
    ralph_dir="$RALPH_DIR"
  else
    ralph_dir="$(cd "$_JEV_POLICY_LIB_DIR/../.." && pwd)"
  fi
  printf '%s\n' "$ralph_dir/jev/questions.registry.json"
}

# Emit the question-set object for <id>, or return 1 if unknown/unreadable.
_jev_policy_load_set() {
  local id="${1:-}"
  local registry set_json

  [[ -n "$id" ]] || return 1
  registry="$(_jev_policy_registry_path)"
  [[ -f "$registry" ]] || return 1

  set_json="$(jq -c --arg id "$id" '
    .questionSets[$id] // empty
  ' "$registry" 2>/dev/null)" || return 1

  [[ -n "$set_json" ]] || return 1
  printf '%s\n' "$set_json"
}

# Emit the questions object for a registered set.
jev_policy_questions() {
  local id="${1:-}"
  local set_json

  [[ -n "$id" ]] || return 1
  set_json="$(_jev_policy_load_set "$id")" || return 1
  jq -c '.questions' <<<"$set_json" 2>/dev/null || return 1
}

# Emit policy.primaryQuestion for a registered set, or return 1 when the set is
# unknown or declares no primary question.
jev_policy_primary_question() {
  local id="${1:-}"
  local set_json primary

  [[ -n "$id" ]] || return 1
  set_json="$(_jev_policy_load_set "$id")" || return 1
  primary="$(jq -r '.policy.primaryQuestion // empty' <<<"$set_json" 2>/dev/null)" || return 1
  [[ -n "$primary" ]] || return 1
  printf '%s\n' "$primary"
}

# Emit actThreshold or escalateThreshold for a registered set.
# Thresholds are registry-only; which must be exactly "act" or "escalate".
jev_policy_threshold() {
  local id="${1:-}"
  local which="${2:-}"
  local set_json key

  [[ -n "$id" ]] || return 1
  case "$which" in
    act) key="actThreshold" ;;
    escalate) key="escalateThreshold" ;;
    *) return 1 ;;
  esac

  set_json="$(_jev_policy_load_set "$id")" || return 1
  jq -r --arg k "$key" '
    .policy[$k] // empty
  ' <<<"$set_json" 2>/dev/null || return 1
}

# Emit Section E decision JSON for answers against a registered set's policy.
# answers_json is the answers object (question id -> answer), not the full response.
#
# Shadow mode (RALPH_JEV_SHADOW=1): compute and record the would-have decision
# (decision field keeps act|gather|fallback; shadow=true), then return a copy
# whose decision is always "fallback" so callers keep their deterministic path.
jev_policy_decide() {
  local id="${1:-}"
  local answers_json="${2:-}"
  local set_json out returned

  [[ -n "$id" && -n "$answers_json" ]] || return 1
  set_json="$(_jev_policy_load_set "$id")" || return 1

  out="$(jq -nc --argjson set "$set_json" --argjson answers "$answers_json" --arg qsid "$id" '
    ($set.policy.primaryQuestion // null) as $pq
    | if ($pq | type) != "string" or ($pq | length) == 0 then
        empty
      else
        ($answers[$pq] // null) as $ans
        | if $ans == null or ($ans | type) != "object" then
            empty
          else
            # Confidence: choice/score use .confidence; noul has no confidence — use .noul.
            (if (($ans.type // "") == "noul")
                or (($ans | has("noul"))
                    and ($ans | has("choice") | not)
                    and ($ans | has("score") | not)) then
               $ans.noul
             elif $ans | has("confidence") then
               $ans.confidence
             else
               null
             end) as $conf
            | if $conf == null or (($conf | type) != "number") then
                empty
              else
                ($ans.choice // null) as $chosen
                | ($set.questions[$pq].criteria // null) as $crit
                | ($set.version // 1) as $ver
                | (
                    ($ans | has("choice"))
                    and ($crit != null)
                    and (($crit | type) == "object")
                    and (($crit | length) > 0)
                    and ($chosen != null)
                    and (($crit | has($chosen | tostring)) | not)
                  ) as $unoffered
                | if $unoffered then
                    {
                      decision: "fallback",
                      chosen: $chosen,
                      confidence: $conf,
                      questionSetId: $qsid,
                      questionSetVersion: $ver,
                      reason: "option-not-offered"
                    }
                  else
                    ($set.policy.actThreshold) as $act
                    | ($set.policy.escalateThreshold) as $esc
                    | if $conf >= $act then
                        {
                          decision: "act",
                          chosen: $chosen,
                          confidence: $conf,
                          questionSetId: $qsid,
                          questionSetVersion: $ver,
                          reason: "act"
                        }
                      elif $conf >= $esc then
                        {
                          decision: "gather",
                          chosen: $chosen,
                          confidence: $conf,
                          questionSetId: $qsid,
                          questionSetVersion: $ver,
                          reason: "gather"
                        }
                      else
                        {
                          decision: "fallback",
                          chosen: $chosen,
                          confidence: $conf,
                          questionSetId: $qsid,
                          questionSetVersion: $ver,
                          reason: "fallback"
                        }
                      end
                  end
              end
          end
      end
  ' 2>/dev/null)" || return 1

  [[ -n "$out" ]] || return 1

  if [[ "${RALPH_JEV_SHADOW:-}" == "1" ]]; then
    # Record the would-have decision; never let telemetry failure affect the return.
    _jev_policy_shadow_record "$out" "$set_json" "$answers_json" || true
    returned="$(
      jq -c '
        .decision = "fallback"
        | .shadow = true
        | .fallbackUsed = true
        | .reason = "shadow"
      ' <<<"$out" 2>/dev/null
    )" || returned=""
    if [[ -n "$returned" ]]; then
      printf '%s\n' "$returned"
      return 0
    fi
    # jq failed: still force fallback for the caller.
    printf '%s\n' '{"decision":"fallback","chosen":null,"confidence":0,"questionSetId":"","questionSetVersion":1,"reason":"shadow","shadow":true}'
    return 0
  fi

  printf '%s\n' "$out"
}

# Print a shadow-mode calibration report over decisions.jsonl.
# Args: optional path to decisions.jsonl (default: <state_dir>/decisions.jsonl).
# Requires python3. Exit 1 when python3 or the report script is unavailable.
jev_shadow_report() {
  local path="${1:-}"
  local py="$_JEV_SHADOW_REPORT_PY"

  if [[ -z "$path" ]]; then
    path="$(_jev_policy_state_dir)/decisions.jsonl"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for jev_shadow_report." >&2
    return 1
  fi
  if [[ ! -f "$py" ]]; then
    echo "Error: jev_shadow_report.py not found at $py" >&2
    return 1
  fi

  python3 "$py" "$path"
}
