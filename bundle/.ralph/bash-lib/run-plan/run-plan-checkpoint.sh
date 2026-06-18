#!/usr/bin/env bash
#
# Checkpoint durability for RALPH_PLAN_SESSION_STRATEGY=checkpoint.
# Writes under RALPH_SESSION_DIR (typically .ralph-workspace/sessions/<PLAN_KEY>/):
#   checkpoint.md              -- human-readable log (one ## TODO line section per completed TODO; oldest sections rolled off using RALPH_CHECKPOINT_ROLLOVER_MAX_MD_BYTES)
#   checkpoint.json            -- structured entries (rollover caps + rollover.* omitted counts)
#   invocation-context-ledger.jsonl -- one JSON object per completed TODO (tail-capped via RALPH_CHECKPOINT_ROLLOVER_MAX_LEDGER_LINES)
#
# Public: ralph_checkpoint_persist_completed_todo, ralph_checkpoint_excerpts_for_prompt,
#   ralph_checkpoint_storage_bytes, ralph_checkpoint_injected_bytes, ralph_checkpoint_feed_max_bytes,
#   ralph_checkpoint_write_invocation_output_excerpt
#
# After ralph_checkpoint_excerpts_for_prompt, these reflect the last assembled excerpt (UTF-8 bytes):
#   RALPH_CHECKPOINT_FEED_INJECTED_UTF8_BYTES, RALPH_CHECKPOINT_FEED_OMITTED_UTF8_BYTES,
#   RALPH_CHECKPOINT_FEED_MAX_BYTES_EFFECTIVE

if [[ -n "${RALPH_RUN_PLAN_CHECKPOINT_SH_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_CHECKPOINT_SH_LOADED=1

_ralph_checkpoint_persist_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../python/run-plan-checkpoint-persist.py"

# Copy the tail of OUTPUT_LOG starting after start_byte (wc -c of log before this segment) into excerpt_path.
# Caps disk read using RALPH_AGENT_OUTPUT_MAX_BYTES (default 24000). Python persist summarizes that tail for checkpoint.md (RALPH_CHECKPOINT_OUTPUT_SUMMARY_MAX_BYTES).
# Args: $1 output log path; $2 start byte offset (non-negative integer); $3 excerpt out path
ralph_checkpoint_write_invocation_output_excerpt() {
  local _log="${1:-}" _start="${2:-0}" _out="${3:-}"
  [[ -n "$_out" ]] || return 1
  local _cap="${RALPH_AGENT_OUTPUT_MAX_BYTES:-24000}"
  [[ "$_cap" =~ ^[0-9]+$ ]] || _cap=24000
  [[ "$_start" =~ ^[0-9]+$ ]] || _start=0
  if [[ ! -f "$_log" ]]; then
    : >"$_out"
    return 0
  fi
  tail -c "+$((_start + 1))" "$_log" 2>/dev/null | tail -c "$_cap" >"$_out" || : >"$_out"
}

# Sum on-disk byte sizes of checkpoint.md and checkpoint.json (stdout integer).
# Args: $1 session dir
ralph_checkpoint_storage_bytes() {
  local _sess="${1:-}" _total=0 _name _path _sz
  [[ -n "$_sess" && -d "$_sess" ]] || {
    printf '0'
    return 0
  }
  for _name in checkpoint.md checkpoint.json; do
    _path="${_sess}/${_name}"
    if [[ -f "$_path" ]]; then
      _sz="$(wc -c < "$_path" 2>/dev/null || echo 0)"
      _total=$(( _total + _sz ))
    fi
  done
  printf '%s' "$_total"
}

# Combined UTF-8 feed budget for checkpoint prompt injection (stdout integer).
ralph_checkpoint_feed_max_bytes() {
  local _raw="${RALPH_CHECKPOINT_FEED_MAX_BYTES:-${RALPH_PLAN_CHECKPOINT_MAX_BYTES:-12000}}"
  if [[ ! "$_raw" =~ ^[0-9]+$ ]] || [[ "$_raw" -le 0 ]]; then
    _raw=12000
  fi
  printf '%s' "$_raw"
}

# Trim combined checkpoint excerpt to the feed UTF-8 budget.
# Args: $1 excerpt text; $2 feed max bytes (optional); $3 name of variable to receive trimmed text;
#   optional $4/$5/$6 names for injected, omitted, and effective feed max (integers).
ralph_checkpoint_apply_feed_budget() {
  local _text="${1:-}" _feed_max="${2:-}" _out_name="${3:-}" _inj_name="${4:-}" _omit_name="${5:-}" _max_name="${6:-}"
  if [[ -z "$_feed_max" ]]; then
    _feed_max="$(ralph_checkpoint_feed_max_bytes)"
  elif [[ ! "$_feed_max" =~ ^[0-9]+$ ]] || [[ "$_feed_max" -le 0 ]]; then
    _feed_max="$(ralph_checkpoint_feed_max_bytes)"
  fi
  local _inj=0 _omit=0 _trimmed=""
  if [[ -z "$_text" ]]; then
    :
  elif ! command -v python3 &>/dev/null; then
    _trimmed="$_text"
    _inj="${#_text}"
  else
  local _tmp_in _tmp_out _tmp_meta
  _tmp_in="$(mktemp)"
  _tmp_out="$(mktemp)"
  _tmp_meta="$(mktemp)"
  printf '%s' "$_text" >"$_tmp_in"
  python3 - "$_feed_max" "$_tmp_in" "$_tmp_out" "$_tmp_meta" <<'PY'
import sys
from pathlib import Path

cap = int(sys.argv[1])
in_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])
meta_path = Path(sys.argv[4])
text = in_path.read_text(encoding="utf-8", errors="replace")
raw = text.encode("utf-8")
total = len(raw)
if total <= cap:
    trimmed = text
    omitted = 0
else:
    omitted = total - cap
    note = (
        f"[Note: checkpoint feed trimmed to last {cap} UTF-8 bytes "
        f"(combined excerpt budget; {omitted} bytes omitted from prefix)]\n"
    )
    note_b = note.encode("utf-8")
    body_cap = cap - len(note_b)
    if body_cap < 0:
        body_cap = 0
    body = raw[-body_cap:].decode("utf-8", errors="replace") if body_cap else ""
    trimmed = note + body
injected = len(trimmed.encode("utf-8"))
out_path.write_text(trimmed, encoding="utf-8")
meta_path.write_text(f"{injected}\t{omitted}\t{cap}\n", encoding="utf-8")
PY
  IFS=$'\t' read -r _inj _omit _feed_max <"$_tmp_meta" || true
  _trimmed="$(<"$_tmp_out")"
  rm -f "$_tmp_in" "$_tmp_out" "$_tmp_meta"
  fi
  if [[ -n "$_out_name" ]]; then
    # shellcheck disable=SC2086
    eval "$(printf '%s=%q' "$_out_name" "$_trimmed")"
  fi
  if [[ -n "$_inj_name" ]]; then
    # shellcheck disable=SC2086
    eval "$(printf '%s=%q' "$_inj_name" "${_inj:-0}")"
  fi
  if [[ -n "$_omit_name" ]]; then
    # shellcheck disable=SC2086
    eval "$(printf '%s=%q' "$_omit_name" "${_omit:-0}")"
  fi
  if [[ -n "$_max_name" ]]; then
    # shellcheck disable=SC2086
    eval "$(printf '%s=%q' "$_max_name" "$_feed_max")"
  fi
  export RALPH_CHECKPOINT_FEED_INJECTED_UTF8_BYTES="${_inj:-0}"
  export RALPH_CHECKPOINT_FEED_OMITTED_UTF8_BYTES="${_omit:-0}"
  export RALPH_CHECKPOINT_FEED_MAX_BYTES_EFFECTIVE="$_feed_max"
}

# Populate prompt excerpt and UTF-8 byte stats (no subshell; safe for run-plan-core).
# Args: $1 session dir; $2 per-file max bytes; $3 excerpt out var; $4 injected out var;
#   optional $5 omitted out var; optional $6 feed max out var.
ralph_checkpoint_fill_prompt_excerpt() {
  local _sess="${1:-}" _cap="${2:-}" _text_var="${3:-}" _inj_var="${4:-}" _omit_var="${5:-}" _feed_var="${6:-}"
  local _out="" _inj=0 _omit=0 _feed_max
  _feed_max="$(ralph_checkpoint_feed_max_bytes)"
  [[ -n "$_sess" && -d "$_sess" ]] || {
    [[ -n "$_text_var" ]] && printf -v "$_text_var" '%s' ""
    [[ -n "$_inj_var" ]] && printf -v "$_inj_var" '%s' "0"
    [[ -n "$_omit_var" ]] && printf -v "$_omit_var" '%s' "0"
    [[ -n "$_feed_var" ]] && printf -v "$_feed_var" '%s' "$_feed_max"
    return 0
  }
  if [[ -z "$_cap" ]]; then
    _cap="${RALPH_PLAN_CHECKPOINT_MAX_BYTES:-12000}"
  fi
  if [[ ! "$_cap" =~ ^[0-9]+$ ]] || [[ "$_cap" -le 0 ]]; then
    _cap=12000
  fi
  local _name _path _sz
  for _name in checkpoint.md checkpoint.json; do
    _path="${_sess}/${_name}"
    if [[ -f "$_path" ]] && [[ -s "$_path" ]]; then
      _out+=$'\n\n'"### ${_name}"
      _sz="$(wc -c < "$_path" 2>/dev/null || echo 0)"
      if [[ "$_sz" -gt "$_cap" ]]; then
        _out+=$'\n'"[Note: trimmed to last ${_cap} bytes]"$'\n'"$(tail -c "$_cap" "$_path" 2>/dev/null || true)"
      else
        _out+=$'\n'"$(<"$_path")"
      fi
    fi
  done
  if [[ -n "$_out" ]]; then
    ralph_checkpoint_apply_feed_budget \
      "$_out" \
      "$_feed_max" \
      "${_text_var:-_out}" \
      "${_inj_var:-_inj}" \
      "${_omit_var:-_omit}" \
      "${_feed_var:-_feed_max}"
  else
    [[ -n "$_text_var" ]] && printf -v "$_text_var" '%s' ""
    [[ -n "$_inj_var" ]] && printf -v "$_inj_var" '%s' "0"
    [[ -n "$_omit_var" ]] && printf -v "$_omit_var" '%s' "0"
    [[ -n "$_feed_var" ]] && printf -v "$_feed_var" '%s' "$_feed_max"
  fi
  if [[ -n "$_inj_var" ]]; then
    # shellcheck disable=SC2086
    eval "_inj=\${${_inj_var}:-0}"
  fi
  if [[ -n "$_omit_var" ]]; then
    # shellcheck disable=SC2086
    eval "_omit=\${${_omit_var}:-0}"
  fi
  export RALPH_CHECKPOINT_FEED_INJECTED_UTF8_BYTES="${_inj:-0}"
  export RALPH_CHECKPOINT_FEED_OMITTED_UTF8_BYTES="${_omit:-0}"
  export RALPH_CHECKPOINT_FEED_MAX_BYTES_EFFECTIVE="$_feed_max"
}

# Byte length of the checkpoint excerpt that would be injected into a prompt (stdout integer, UTF-8).
# Args: $1 session dir; $2 max bytes per file (optional; default RALPH_PLAN_CHECKPOINT_MAX_BYTES or 12000).
ralph_checkpoint_injected_bytes() {
  local _sess="${1:-}" _cap="${2:-}" _inj=0
  [[ -n "$_sess" && -d "$_sess" ]] || {
    printf '0'
    return 0
  }
  ralph_checkpoint_fill_prompt_excerpt "$_sess" "$_cap" "" "_inj"
  printf '%s' "${_inj:-0}"
}

# Emit markdown sections for checkpoint.md and checkpoint.json under session_dir (stdout).
# Args: $1 session dir; $2 max bytes per file (optional; default RALPH_PLAN_CHECKPOINT_MAX_BYTES or 12000).
# Each existing file is included in full or as tail -c max when larger.
ralph_checkpoint_excerpts_for_prompt() {
  local _sess="${1:-}" _cap="${2:-}"
  [[ -n "$_sess" && -d "$_sess" ]] || return 0
  if [[ -z "$_cap" ]]; then
    _cap="${RALPH_PLAN_CHECKPOINT_MAX_BYTES:-12000}"
  fi
  if [[ ! "$_cap" =~ ^[0-9]+$ ]] || [[ "$_cap" -le 0 ]]; then
    _cap=12000
  fi
  local _out="" _name _path _sz
  for _name in checkpoint.md checkpoint.json; do
    _path="${_sess}/${_name}"
    if [[ -f "$_path" ]] && [[ -s "$_path" ]]; then
      _out+=$'\n\n'"### ${_name}"
      _sz="$(wc -c < "$_path" 2>/dev/null || echo 0)"
      if [[ "$_sz" -gt "$_cap" ]]; then
        _out+=$'\n'"[Note: trimmed to last ${_cap} bytes]"$'\n'"$(tail -c "$_cap" "$_path" 2>/dev/null || true)"
      else
        _out+=$'\n'"$(<"$_path")"
      fi
    fi
  done
  if [[ -n "$_out" ]]; then
    ralph_checkpoint_apply_feed_budget "$_out" "" "_out"
  else
    export RALPH_CHECKPOINT_FEED_INJECTED_UTF8_BYTES=0
    export RALPH_CHECKPOINT_FEED_OMITTED_UTF8_BYTES=0
    export RALPH_CHECKPOINT_FEED_MAX_BYTES_EFFECTIVE="$(ralph_checkpoint_feed_max_bytes)"
  fi
  printf '%s' "$_out"
}

# Persist checkpoint artifacts after a TODO is marked complete (checkpoint strategy only).
# Args:
#   $1 workspace root
#   $2 session dir (RALPH_SESSION_DIR)
#   $3 plan path
#   $4 line number
#   $5 task ordinal
#   $6 todo hash
#   $7 iteration
#   $8 exit code
#   $9 direct verification (1/0)
#  $10 completion sentinel present (1/0)
#  $11 optional context ledger file path (may be missing)
# Uses temp files for todo text and git snapshots; caller passes todo text file path as $12.
#  $13 plan-runner output log path (optional; may be empty)
#  $14 invocation output excerpt file path (optional; UTF-8 bytes from this run, typically tail-capped)
#  $15 verification scope (optional: phase|todo|final)
#  $16 verification gate name/reference (optional)
#  $17 verification command string (optional)
#  $18 verification declared flag (optional 1/0)
#  $19 verification deferred flag (optional 1/0)
#  $20 verification exit code (optional)
#  $21 verification failed command (optional)
#  $22 path to declared gate results JSON (optional; see run-plan-checkpoint-persist.py)
#  $23 record kind (optional; empty or "declared_gate_tail" for post-invocation gate-only checkpoint rows)
ralph_checkpoint_persist_completed_todo() {
  [[ "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" == "checkpoint" ]] || return 0
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || return 0
  command -v python3 &>/dev/null || {
    if declare -F ralph_run_plan_log &>/dev/null; then
      ralph_run_plan_log "checkpoint persist skipped: python3 not on PATH"
    fi
    return 0
  }

  local _ws="$1" _sess="$2" _plan="$3" _line="$4" _ord="$5" _hash="$6" _iter="$7" _ex="$8" _dv="$9" _sent="${10}" _ledger="${11}" _todo_file="${12:-}" _out_log="${13:-}" _excerpt_file="${14:-}" _verification_scope="${15:-}" _verification_gate_name="${16:-}" _verification_command="${17:-}" _verification_declared="${18:-}" _verification_deferred="${19:-}" _verification_exit_code="${20:-}" _verification_failed_command="${21:-}" _gate_results="${22:-}" _record_kind="${23:-}"
  [[ -n "$_todo_file" && -f "$_todo_file" ]] || return 1
  [[ -n "${RALPH_PLAN_KEY:-}" ]] || return 1

  local _gb _ga
  _gb="$(mktemp)"
  _ga="$(mktemp)"
  printf '%s' "${GIT_STATUS_AT_START:-}" >"$_gb"
  printf '%s' "${GIT_STATUS_AT_END:-}" >"$_ga"

  mkdir -p "$_sess"
  chmod 700 "$_sess" 2>/dev/null || true

  if ! python3 "$_ralph_checkpoint_persist_py" \
    "$_ws" \
    "$_sess" \
    "$_plan" \
    "${RALPH_PLAN_KEY}" \
    "$_line" \
    "$_ord" \
    "$_hash" \
    "$_iter" \
    "$_ex" \
    "$_dv" \
    "$_sent" \
    "$_todo_file" \
    "$_gb" \
    "$_ga" \
    "${_ledger}" \
    "${_out_log}" \
    "${_excerpt_file}" \
    "${_verification_scope}" \
    "${_verification_gate_name}" \
    "${_verification_command}" \
    "${_verification_declared}" \
    "${_verification_deferred}" \
    "${_verification_exit_code}" \
    "${_verification_failed_command}" \
    "${_gate_results}" \
    "${_record_kind}"; then
    rm -f "$_gb" "$_ga"
    if declare -F ralph_run_plan_log &>/dev/null; then
      ralph_run_plan_log "WARNING: checkpoint persist helper returned non-zero"
    fi
    return 0
  fi
  rm -f "$_gb" "$_ga"
  return 0
}

# Reset a JSON accumulator used for declared verification gate runs (list of objects).
ralph_checkpoint_declared_gate_json_reset() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  python3 -c 'import json,sys; json.dump([], open(sys.argv[1],"w"), indent=2)' "$path"
}

# Append one gate record (command read from cmd_file). Args: json_path gate_name exit_code elapsed_sec log_path cmd_file
ralph_checkpoint_append_declared_gate_record() {
  local json_path="$1" gate_name="$2" exit_code="$3" elapsed_sec="$4" log_path="$5" cmd_file="$6"
  [[ -f "$cmd_file" ]] || return 1
  python3 - "$json_path" "$gate_name" "$exit_code" "$elapsed_sec" "$log_path" "$cmd_file" <<'PY'
import json
import pathlib
import sys

path, name, ex, el, lp, cmdf = sys.argv[1:7]
cmd = pathlib.Path(cmdf).read_text(encoding="utf-8", errors="replace")
rec = {
    "gate_name": name,
    "command": cmd.rstrip("\n"),
    "exit_code": int(ex),
    "elapsed_seconds": int(el),
    "log_path": lp,
}
try:
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError, TypeError):
    data = []
if not isinstance(data, list):
    data = []
data.append(rec)
pathlib.Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

# Run declared gates from stdin (one `gate_name<TAB>command` per line). Writes stdout/stderr of each gate
# to session_dir/gate-logs; appends structured records to json_path. Appends human-readable markers to output_log.
# Args: workspace output_log session_dir plan_iteration json_accum_path
# Returns 0 when every gate exits 0 and is allowlisted; non-zero on first failure.
ralph_declared_gates_run_pairs_streaming_logs() {
  local workdir="$1" output_log="$2" session_dir="$3" plan_iteration="$4" json_accum="$5"
  [[ -n "$workdir" && -n "$output_log" && -n "$session_dir" && -n "$json_accum" ]] || return 1
  mkdir -p "$session_dir/gate-logs" || return 1
  local -i _gi=0 _all=1
  local _line _gn _gc _safe _glog _t0 _t1 _elapsed _gx _cmdf
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _gn="${_line%%$'\t'*}"
    _gc="${_line#*$'\t'}"
    [[ -z "$_gc" ]] && continue
    _gi+=1
    if ! ralph_plan_verification_command_allowlisted "$_gc"; then
      _cmdf="$(mktemp)"
      printf '%s' "$_gc" >"$_cmdf"
      ralph_checkpoint_append_declared_gate_record "$json_accum" "$_gn" "126" "0" "" "$_cmdf"
      rm -f "$_cmdf"
      {
        echo ""
        echo "--- Declared verification gate FAILED (not allowlisted): $_gc ---"
      } >>"$output_log"
      if declare -F ralph_run_plan_log &>/dev/null; then
        ralph_run_plan_log "declared verification FAILED (not allowlisted): $_gc"
      fi
      _all=0
      break
    fi
    if declare -F ralph_run_plan_log &>/dev/null; then
      ralph_run_plan_log "declared verification running: $_gc"
    fi
    echo -e "${C_G}Running declared verification gate ${_gn}${C_RST}" >&2
    _safe="$(printf '%s' "$_gn" | tr -c 'a-z0-9_-_' '_')"
    _glog="$session_dir/gate-logs/${RALPH_PLAN_KEY:-plan}-iter${plan_iteration}-${_safe}-${_gi}.log"
    : >"$_glog"
    {
      echo "Command: $_gc"
      echo "Gate output log: $_glog"
      echo ""
    } >>"$output_log"
    _t0="$(date +%s)"
    set +e
    (cd "$workdir" && bash -lc "$_gc") >>"$_glog" 2>&1
    _gx=$?
    set -e
    _t1="$(date +%s)"
    _elapsed=$((_t1 - _t0))
    _cmdf="$(mktemp)"
    printf '%s' "$_gc" >"$_cmdf"
    ralph_checkpoint_append_declared_gate_record "$json_accum" "$_gn" "$_gx" "$_elapsed" "$_glog" "$_cmdf"
    rm -f "$_cmdf"
    if [[ "$_gx" -ne 0 ]]; then
      {
        echo ""
        echo "--- Declared verification gate FAILED (exit $_gx): $_gc ---"
      } >>"$output_log"
      if declare -F ralph_run_plan_log &>/dev/null; then
        ralph_run_plan_log "declared verification FAILED: cmd=$_gc exit=$_gx"
      fi
      _all=0
      break
    fi
    if declare -F ralph_run_plan_log &>/dev/null; then
      ralph_run_plan_log "declared verification gate passed: cmd=$_gc"
    fi
  done
  return $((1 - _all))
}
