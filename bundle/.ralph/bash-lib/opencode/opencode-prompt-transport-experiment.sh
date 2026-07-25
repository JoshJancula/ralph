#!/usr/bin/env bash
# Deterministic OpenCode prompt-transport experiment (PLAN25 Phase 7).
# Compares baseline PROMPT_STATIC-in-user-prompt vs Ralph-owned --file transport.
# Does not edit project AGENTS.md or user/global opencode.json.

if [[ -n "${RALPH_OPENCODE_PROMPT_TRANSPORT_EXPERIMENT_LOADED:-}" ]]; then
  return 0
fi
RALPH_OPENCODE_PROMPT_TRANSPORT_EXPERIMENT_LOADED=1

_ralph_oc_exp_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ralph_oc_exp_demux="${_ralph_oc_exp_lib_dir}/../python/run-plan-cli-json-demux.py"
# shellcheck source=/dev/null
source "$_ralph_oc_exp_lib_dir/opencode-prompt-transport.sh"

ralph_opencode_experiment_report_path() {
  local workspace="$1"
  local artifact_ns="${2:-experiment}"
  printf '%s/.ralph-workspace/artifacts/%s/opencode-prompt-transport-experiment.json' \
    "$workspace" "$artifact_ns"
}

# Build argv for one experiment arm (prints NUL-separated lines for testing, or sets vars).
# Usage: ralph_opencode_experiment_build_argv <mode:baseline|candidate> <workspace> <ns> <dynamic> <static>
# Sets: RALPH_OC_EXP_PROMPT, RALPH_OC_EXP_ARGS (bash array name passed as $6)
ralph_opencode_experiment_build_argv() {
  local mode="$1"
  local workspace="$2"
  local artifact_ns="$3"
  local dynamic="$4"
  local static="$5"
  local args_name="$6"

  local -a _args=(run --agent implementation --format json)
  case "$mode" in
    baseline)
      export RALPH_OC_EXP_PROMPT="${dynamic}"$'\n'"${static}"
      export RALPH_OC_EXP_STATIC_IN_USER_PROMPT=1
      export RALPH_OC_EXP_STATIC_FILE=""
      _args+=("$RALPH_OC_EXP_PROMPT")
      ;;
    candidate)
      local static_path
      static_path="$(ralph_opencode_static_artifact_path "$workspace" "$artifact_ns")"
      mkdir -p "$(dirname "$static_path")"
      printf '%s\n' "$static" >"$static_path"
      export RALPH_OC_EXP_PROMPT="$dynamic"
      export RALPH_OC_EXP_STATIC_IN_USER_PROMPT=0
      export RALPH_OC_EXP_STATIC_FILE="$static_path"
      _args+=(--file "$static_path")
      _args+=("$dynamic")
      ;;
    *)
      echo "ralph_opencode_experiment_build_argv: unknown mode '$mode'" >&2
      return 1
      ;;
  esac
  eval "$args_name=(\"\${_args[@]}\")"
}

# Run both arms twice (simulating two TODOs with stable static) and write a JSON report.
# Requires OPENCODE_PLAN_CLI (or first arg) pointing at a stub or real opencode that emits
# JSON lines with step_finish token fields on stdout.
#
# Usage: ralph_opencode_prompt_transport_experiment_run <workspace> <artifact_ns> <dynamic> <static> [opencode_cli]
ralph_opencode_prompt_transport_experiment_run() {
  local workspace="$1"
  local artifact_ns="$2"
  local dynamic="$3"
  local static="$4"
  local cli="${5:-${OPENCODE_PLAN_CLI:-}}"

  if [[ -z "$cli" ]]; then
    echo "ralph_opencode_prompt_transport_experiment_run: OpenCode CLI not set" >&2
    return 1
  fi
  if ! command -v "$cli" &>/dev/null; then
    echo "ralph_opencode_prompt_transport_experiment_run: CLI not found: $cli" >&2
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    echo "ralph_opencode_prompt_transport_experiment_run: python3 required" >&2
    return 1
  fi

  local report_path
  report_path="$(ralph_opencode_experiment_report_path "$workspace" "$artifact_ns")"
  mkdir -p "$(dirname "$report_path")"

  local tmpdir
  tmpdir="$(mktemp -d)"

  local arm inv usage_file record
  for arm in baseline candidate; do
    for inv in 1 2; do
      usage_file="$tmpdir/${arm}-inv${inv}.usage.json"
      record="$tmpdir/${arm}-inv${inv}.argv"
      : >"$record"
      local -a argv=()
      ralph_opencode_experiment_build_argv "$arm" "$workspace" "$artifact_ns" "$dynamic" "$static" argv
      printf '%s\n' "${argv[@]}" >"$record"

      local out_log="$tmpdir/${arm}-inv${inv}.out"
      export RALPH_OC_EXP_ARM="$arm"
      export RALPH_OC_EXP_INV="$inv"
      "$cli" "${argv[@]}" >"$out_log" 2>&1 || true

      if [[ -f "$_ralph_oc_exp_demux" ]]; then
        python3 "$_ralph_oc_exp_demux" opencode "" "$usage_file" <"$out_log" 2>/dev/null || true
      fi
    done
  done

  python3 - "$workspace" "$artifact_ns" "$dynamic" "$static" "$report_path" "$tmpdir" <<'PY'
import json
import os
import sys
from pathlib import Path

workspace, ns, dynamic, static, report_path, tmpdir = sys.argv[1:7]
static_len = len(static.encode("utf-8"))
dynamic_len = len(dynamic.encode("utf-8"))
baseline_user = dynamic_len + 1 + static_len
candidate_user = dynamic_len

def load_usage(arm, inv):
    p = Path(tmpdir) / f"{arm}-inv{inv}.usage.json"
    if not p.is_file():
        return {}
    with p.open(encoding="utf-8") as fh:
        return json.load(fh)

def sum_tokens(usage):
    inp = int(usage.get("input_tokens") or 0)
    cache_read = int(usage.get("cache_read_input_tokens") or 0)
    cache_write = int(usage.get("cache_creation_input_tokens") or 0)
    return inp + cache_read, cache_read, inp

arms = {}
for arm in ("baseline", "candidate"):
    invs = []
    for inv in (1, 2):
        u = load_usage(arm, inv)
        pressure, cache_read, inp = sum_tokens(u)
        ratio = (cache_read / inp) if inp else 0.0
        invs.append({
            "invocation": inv,
            "input_tokens": inp,
            "cache_read_input_tokens": cache_read,
            "cache_creation_input_tokens": int(u.get("cache_creation_input_tokens") or 0),
            "token_pressure": pressure,
            "cache_hit_ratio": round(ratio, 4),
        })
    inv2 = invs[1] if len(invs) > 1 else invs[0]
    arms[arm] = {
        "invocations": invs,
        "user_prompt_bytes": baseline_user if arm == "baseline" else candidate_user,
        "static_in_user_prompt": arm == "baseline",
        "static_via_ralph_file": arm == "candidate",
        "static_prompt_bytes_accounting": static_len if arm == "baseline" else 0,
        "post_first_cache_hit_ratio": inv2["cache_hit_ratio"],
    }

b1 = arms["baseline"]["invocations"][0]["token_pressure"] if arms["baseline"]["invocations"] else 0
b2 = arms["baseline"]["invocations"][1]["token_pressure"] if len(arms["baseline"]["invocations"]) > 1 else b1
c2 = arms["candidate"]["invocations"][1]["token_pressure"] if len(arms["candidate"]["invocations"]) > 1 else 0
drop_pct = 0.0
if b2 > 0:
    drop_pct = round(100.0 * (b2 - c2) / b2, 2)

cache_pass = arms["candidate"]["post_first_cache_hit_ratio"] > 0.9
budget_pass = drop_pct >= 30.0 and not arms["candidate"]["static_in_user_prompt"]
static_removed = arms["candidate"]["static_prompt_bytes_accounting"] == 0

prompt_budget_improved = candidate_user < baseline_user
cache_improved = cache_pass

# Falsifiable verdict: cache hypothesis vs prompt-budget hypothesis.
if cache_improved and static_removed:
    cache_verdict = "SUPPORTED"
elif cache_improved:
    cache_verdict = "SUPPORTED_PARTIAL"
else:
    cache_verdict = "NOT_SUPPORTED"

if budget_pass and static_removed:
    budget_verdict = "SUPPORTED"
elif prompt_budget_improved and static_removed:
    budget_verdict = "STRUCTURAL_ONLY"
else:
    budget_verdict = "NOT_SUPPORTED"

# Phase 10 in PLAN25 is conditional on measurable benefit; cache failure blocks speculative transport.
if cache_verdict == "NOT_SUPPORTED":
    if budget_verdict in ("SUPPORTED", "STRUCTURAL_ONLY"):
        phase10 = "HOLD_CACHE_UNPROVEN_PROMPT_BUDGET_OK"
    else:
        phase10 = "DO_NOT_CHANGE_TRANSPORT"
elif cache_verdict.startswith("SUPPORTED") and static_removed:
    phase10 = "LIVE_VALIDATION_REQUIRED"
else:
    phase10 = "DO_NOT_CHANGE_TRANSPORT"

report = {
    "experiment": "opencode-prompt-transport",
    "artifact_namespace": ns,
    "workspace": workspace,
    "baseline_transport": "PROMPT_STATIC appended to user prompt (current run-plan-core)",
    "candidate_transport": "Ralph-owned file under .ralph-workspace/artifacts via opencode run --file",
    "constraints": {
        "agents_md_mutated": False,
        "user_opencode_config_mutated": False,
    },
    "arms": arms,
    "comparison": {
        "baseline_user_prompt_bytes": baseline_user,
        "candidate_user_prompt_bytes": candidate_user,
        "user_prompt_byte_reduction": baseline_user - candidate_user,
        "token_pressure_drop_percent_inv2": drop_pct,
    },
    "verdicts": {
        "cache_hypothesis": cache_verdict,
        "prompt_budget_hypothesis": budget_verdict,
        "phase_10_gate": phase10,
    },
    "recommendation": "",
    "pass_fail_criteria_source": ".ralph-workspace/artifacts/PLAN25/token-optimization-baseline.md",
}

if cache_verdict == "NOT_SUPPORTED":
    if budget_verdict in ("SUPPORTED", "STRUCTURAL_ONLY"):
        report["recommendation"] = (
            "Cache hypothesis NOT SUPPORTED in this fixture (cache_hit_ratio did not exceed 0.9 after the first invocation). "
            "User-prompt byte budget improved structurally via --file, but do not force a speculative runtime transport change for cache in PLAN25 Phase 10. "
            "Live OpenCode with setCacheKey and session continuity is required to falsify or confirm provider-side caching."
        )
    else:
        report["recommendation"] = (
            "FAIL: No measurable cache or prompt-budget improvement vs baseline in this fixture. "
            "Do not implement Phase 10 OpenCode transport change from this experiment alone."
        )
else:
    report["recommendation"] = (
        "Fixture suggests cache benefit; run live OpenCode validation before changing production transport."
    )

Path(report_path).parent.mkdir(parents=True, exist_ok=True)
Path(report_path).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(report_path)
print(json.dumps(report["verdicts"]))
PY

  rm -rf "$tmpdir"
  return 0
}
