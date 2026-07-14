#!/usr/bin/env bash
# Offline, reproducible grep-pathology benchmark helper (PLAN15).
#
# Generates a temporary grep corpus with both many matches and a small number
# of extremely long matching lines, then measures the current unbounded proxy
# grep capture path: full source capture, Bash-variable load, token
# estimation, the inline candidate after max_matches, and the final preview.
#
# Does not touch the network and does not commit the generated corpus. Writes
# a markdown report to the path given as $1 (default:
# .ralph-workspace/artifacts/<ns>/grep-source-cap-baseline.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/bundle/.ralph/bash-lib/token-estimate.sh"

bench_grep_cap_ns() {
  printf '%s\n' "${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-PLAN15-compaction-telemetry-hardening}}"
}

bench_grep_cap_default_report_path() {
  printf '%s\n' "$REPO_ROOT/.ralph-workspace/artifacts/$(bench_grep_cap_ns)/grep-source-cap-baseline.md"
}

# Populates $corpus_dir/corpus.txt with:
#   - MANY_MATCH_LINES short lines matching PATTERN
#   - a handful of HUGE_LINE_BYTES-byte lines that also match PATTERN
bench_grep_cap_generate_corpus() {
  local corpus_dir="$1"
  local many_lines="${2:-200000}"
  local huge_lines="${3:-3}"
  local huge_bytes="${4:-2000000}"
  local pattern="${5:-NEEDLE}"

  mkdir -p "$corpus_dir"
  local out="$corpus_dir/corpus.txt"
  : >"$out"

  awk -v n="$many_lines" -v pat="$pattern" '
    BEGIN {
      for (i = 0; i < n; i++) {
        printf "line %d %s marker filler text for search corpus generation\n", i, pat
      }
    }
  ' >>"$out"

  local i=0
  while [[ "$i" -lt "$huge_lines" ]]; do
    awk -v bytes="$huge_bytes" -v pat="$pattern" '
      BEGIN {
        line = pat " "
        chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
        while (length(line) < bytes) {
          line = line chunk
        }
        print substr(line, 1, bytes)
      }
    ' >>"$out"
    i=$((i + 1))
  done
}

# Measures the current (unbounded) capture path used by
# ralph_mcp_proxy_owned_tool_grep: rg writes matches to a temp file, the temp
# file is fully loaded into a Bash variable ("full_text"), then max_matches
# determines the inline candidate, and the byte cap determines the final
# preview. Prints tab-separated metric=value lines to stdout.
bench_grep_cap_measure() {
  local corpus_dir="$1"
  local pattern="${2:-NEEDLE}"
  local max_matches="${3:-100}"
  local preview_byte_cap="${4:-16384}"

  local tmp_out t0 t1
  tmp_out="$(mktemp)"

  if command -v rg >/dev/null 2>&1; then
    t0="$(date +%s.%N)"
    rg --line-number --no-heading --color=never "$pattern" "$corpus_dir" >"$tmp_out" 2>/dev/null || true
    t1="$(date +%s.%N)"
  else
    t0="$(date +%s.%N)"
    grep -rn -- "$pattern" "$corpus_dir" >"$tmp_out" 2>/dev/null || true
    t1="$(date +%s.%N)"
  fi
  local capture_elapsed
  capture_elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.4f", b - a }')"

  local source_captured_bytes
  source_captured_bytes="$(wc -c <"$tmp_out" | tr -d ' ')"

  # This reproduces the defect under test: the full captured file is loaded
  # into a Bash variable before any max_matches/byte-cap limiting is applied.
  t0="$(date +%s.%N)"
  local full_text
  full_text="$(<"$tmp_out")"
  t1="$(date +%s.%N)"
  local load_elapsed
  load_elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.4f", b - a }')"

  t0="$(date +%s.%N)"
  local source_tokens_est
  source_tokens_est="$(ralph_token_estimate_file "$tmp_out" 2>/dev/null || printf '0')"
  t1="$(date +%s.%N)"
  local token_estimate_elapsed
  token_estimate_elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.4f", b - a }')"

  local inline_candidate_text
  inline_candidate_text="$(printf '%s' "$full_text" | head -n "$max_matches")"
  local inline_candidate_bytes
  inline_candidate_bytes="$(printf '%s' "$inline_candidate_text" | wc -c | tr -d ' ')"

  local preview_text
  preview_text="$(printf '%s' "$inline_candidate_text" | head -c "$preview_byte_cap")"
  local preview_bytes
  preview_bytes="$(printf '%s' "$preview_text" | wc -c | tr -d ' ')"

  rm -f "$tmp_out"

  printf 'captureElapsedSeconds\t%s\n' "$capture_elapsed"
  printf 'sourceCapturedBytes\t%s\n' "$source_captured_bytes"
  printf 'bashLoadElapsedSeconds\t%s\n' "$load_elapsed"
  printf 'tokenEstimateElapsedSeconds\t%s\n' "$token_estimate_elapsed"
  printf 'sourceTokensEstimated\t%s\n' "$source_tokens_est"
  printf 'inlineCandidateBytes\t%s\n' "$inline_candidate_bytes"
  printf 'previewBytes\t%s\n' "$preview_bytes"
}

BENCH_GREP_CAP_WORK_DIR=""
bench_grep_cap_cleanup() {
  [[ -n "$BENCH_GREP_CAP_WORK_DIR" ]] && rm -rf "$BENCH_GREP_CAP_WORK_DIR"
}
trap bench_grep_cap_cleanup EXIT

bench_grep_cap_main() {
  local report_path="${1:-$(bench_grep_cap_default_report_path)}"
  mkdir -p "$(dirname "$report_path")"

  BENCH_GREP_CAP_WORK_DIR="$(mktemp -d)"
  local work_dir="$BENCH_GREP_CAP_WORK_DIR"

  bench_grep_cap_generate_corpus "$work_dir" 200000 3 2000000 "NEEDLE"

  local metrics
  metrics="$(bench_grep_cap_measure "$work_dir" "NEEDLE" 100 16384)"

  local rg_version bash_version uname_out
  rg_version="$(command -v rg >/dev/null 2>&1 && rg --version | head -n1 || printf 'not installed (grep fallback used)')"
  bash_version="$BASH_VERSION"
  uname_out="$(uname -a)"

  {
    printf -- '# Grep source-cap pathology baseline (PLAN15)\n\n'
    printf 'Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '## Environment\n\n'
    printf -- '- ripgrep: %s\n' "$rg_version"
    printf -- '- bash: %s\n' "$bash_version"
    printf -- '- uname: %s\n' "$uname_out"
    printf -- '\n## Corpus\n\n'
    printf -- '- 200000 short matching lines + 3 lines of 2000000 bytes each, all matching pattern `NEEDLE`\n'
    printf -- '- generated under a temporary directory, deleted after the run, never committed\n'
    printf -- '\n## Current (unbounded) capture path measurements\n\n'
    printf -- '| metric | value |\n|---|---|\n'
    while IFS=$'\t' read -r k v; do
      printf '| %s | %s |\n' "$k" "$v"
    done <<<"$metrics"
    printf -- '\n## Interpretation\n\n'
    local captured inline
    captured="$(awk -F'\t' '$1=="sourceCapturedBytes"{print $2}' <<<"$metrics")"
    inline="$(awk -F'\t' '$1=="inlineCandidateBytes"{print $2}' <<<"$metrics")"
    printf -- '- sourceCapturedBytes (%s) materially exceeds inlineCandidateBytes (%s): the full match set is loaded into a Bash variable and estimated for tokens even though only the first max_matches lines were ever eligible for inline delivery.\n' "$captured" "$inline"
    printf -- '- These figures are source-captured/inline-candidate/preview bytes as defined in this plan'"'"'s measurement contract; they are not model-context savings by themselves.\n'
  } >"$report_path"

  printf '%s\n' "$report_path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bench_grep_cap_main "${1:-}"
fi
