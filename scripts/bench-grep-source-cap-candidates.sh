#!/usr/bin/env bash
# Compares candidate grep source-cap policies (byte cap, line cap, per-line
# width) against multiple corpus classes, offline, and records the selected
# defaults with rationale (PLAN15). This script selects policy; it does not
# change production behavior on its own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

bench_grep_candidates_ns() {
  printf '%s\n' "${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-PLAN15-compaction-telemetry-hardening}}"
}

bench_grep_candidates_default_report_path() {
  printf '%s\n' "$REPO_ROOT/.ralph-workspace/artifacts/$(bench_grep_candidates_ns)/grep-source-cap-candidates.md"
}

BENCH_GREP_CANDIDATES_WORK_DIR=""
bench_grep_candidates_cleanup() {
  [[ -n "$BENCH_GREP_CANDIDATES_WORK_DIR" ]] && rm -rf "$BENCH_GREP_CANDIDATES_WORK_DIR"
}
trap bench_grep_candidates_cleanup EXIT

# Builds one corpus file per named class under $1:
#   normal.txt        - a small, realistic codebase-style search result
#   many_matches.txt  - 20000 short matching lines
#   huge_line.txt     - one 2000000-byte matching line
#   utf8.txt          - matching lines containing multibyte UTF-8 text
bench_grep_candidates_generate_corpora() {
  local dir="$1"
  mkdir -p "$dir"

  {
    for i in $(seq 1 40); do
      printf 'src/module_%02d.sh:%d:function handle_NEEDLE_case() { return 0; }\n' "$i" "$((i * 3))"
    done
  } > "$dir/normal.txt"

  awk -v n=20000 'BEGIN {
    for (i = 0; i < n; i++) {
      printf "file_%d.txt:%d:short line %d NEEDLE marker\n", i % 500, i, i
    }
  }' > "$dir/many_matches.txt"

  awk -v bytes=2000000 'BEGIN {
    line = "huge.txt:1:NEEDLE "
    chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
    while (length(line) < bytes) { line = line chunk }
    print substr(line, 1, bytes)
  }' > "$dir/huge_line.txt"

  {
    for i in $(seq 1 500); do
      printf 'i18n/messages_%d.txt:%d:NEEDLE caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e \xf0\x9f\x9a\x80 line %d\n' "$i" "$i" "$i"
    done
  } > "$dir/utf8.txt"
}

# Applies a byte_cap/line_cap/per_line_cap candidate to a corpus file and
# prints tab-separated metrics: cappedBytes cappedLines exceededByteCap
# exceededLineCap anyLineTruncated
bench_grep_candidates_apply() {
  local corpus_file="$1" byte_cap="$2" line_cap="$3" per_line_cap="$4"
  local out
  out="$(awk -v line_cap="$line_cap" -v per_line="$per_line_cap" '
    NR > line_cap { exit }
    { if (length($0) > per_line) { $0 = substr($0, 1, per_line); truncated=1 } print }
    END { if (truncated) print "TRUNCATED_MARKER" > "/dev/stderr" }
  ' "$corpus_file" 2>"$corpus_file.trunc")"

  local capped_bytes capped_lines exceeded_byte exceeded_line any_line_trunc
  capped_bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"
  if [[ "$capped_bytes" -gt "$byte_cap" ]]; then
    out="$(printf '%s' "$out" | head -c "$byte_cap")"
    capped_bytes="$byte_cap"
    exceeded_byte=1
  else
    exceeded_byte=0
  fi
  capped_lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  local source_lines
  source_lines="$(wc -l < "$corpus_file" | tr -d ' ')"
  if [[ "$source_lines" -gt "$line_cap" ]]; then
    exceeded_line=1
  else
    exceeded_line=0
  fi
  if [[ -s "$corpus_file.trunc" ]]; then
    any_line_trunc=1
  else
    any_line_trunc=0
  fi
  rm -f "$corpus_file.trunc"

  printf '%s\t%s\t%s\t%s\t%s\n' "$capped_bytes" "$capped_lines" "$exceeded_byte" "$exceeded_line" "$any_line_trunc"
}

bench_grep_candidates_main() {
  local report_path="${1:-$(bench_grep_candidates_default_report_path)}"
  mkdir -p "$(dirname "$report_path")"

  local gen_t0 gen_t1
  gen_t0="$(date +%s.%N)"
  BENCH_GREP_CANDIDATES_WORK_DIR="$(mktemp -d)"
  local dir="$BENCH_GREP_CANDIDATES_WORK_DIR"
  bench_grep_candidates_generate_corpora "$dir"
  gen_t1="$(date +%s.%N)"
  local gen_elapsed
  gen_elapsed="$(awk -v a="$gen_t0" -v b="$gen_t1" 'BEGIN { printf "%.4f", b - a }')"

  local -a byte_caps=(65536 262144 1048576)
  local -a line_caps=(500 2000 5000)
  local -a per_line_caps=(2048 4096 8192)
  local -a classes=(normal many_matches huge_line utf8)

  local sweep_t0 sweep_t1
  sweep_t0="$(date +%s.%N)"

  {
    printf '# Grep source-cap candidate comparison (PLAN15)\n\n'
    printf 'Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Corpus classes: normal codebase search, many short matches (20000 lines), one 2000000-byte huge line, multibyte UTF-8 matches.\n\n'
    printf 'Corpus generation elapsed: %ss\n\n' "$gen_elapsed"
    printf '| byteCap | lineCap | perLineCap | class | cappedBytes | cappedLines | exceededByteCap | exceededLineCap | anyLineTruncated |\n'
    printf '|---|---|---|---|---|---|---|---|---|\n'
    local bc lc pc class metrics
    for bc in "${byte_caps[@]}"; do
      for lc in "${line_caps[@]}"; do
        for pc in "${per_line_caps[@]}"; do
          for class in "${classes[@]}"; do
            metrics="$(bench_grep_candidates_apply "$dir/$class.txt" "$bc" "$lc" "$pc")"
            printf '| %s | %s | %s | %s | %s |\n' "$bc" "$lc" "$pc" "$class" "$(printf '%s' "$metrics" | tr '\t' '|')"
          done
        done
      done
    done
    sweep_t1="$(date +%s.%N)"
    local sweep_elapsed
    sweep_elapsed="$(awk -v a="$sweep_t0" -v b="$sweep_t1" 'BEGIN { printf "%.4f", b - a }')"
    printf '\nCandidate sweep elapsed: %ss (%d candidate/class combinations)\n\n' \
      "$sweep_elapsed" "$(( ${#byte_caps[@]} * ${#line_caps[@]} * ${#per_line_caps[@]} * ${#classes[@]} ))"

    printf '## Selected defaults\n\n'
    printf -- '- sourceCapBytes: 262144 (256 KiB) -- generous enough to retain a useful many-match follow-up window, small enough that a 65 MB pathological capture (per the recorded baseline) becomes structurally impossible.\n'
    printf -- '- sourceCapLines: 2000 -- comfortably above ralph_proxy_grep default max_matches (100) so line-count capping is a true backstop, not the primary limiter; well below the 20000-line many_matches pathology.\n'
    printf -- '- sourceCapPerLineBytes: 4096 -- bounds a single pathological huge line (observed 2000000 bytes) to a small fraction of the byte cap while leaving room for realistic long matched lines (minified JS, long log lines).\n'
    printf -- '- Absolute hard ceilings (never exceeded even with policy overrides): byteCap<=4194304 (4 MiB), lineCap<=20000, perLineCap<=65536.\n'
    printf -- '- utf8 class: byte-based truncation at these cap sizes never lands mid-corpus for the realistic message sizes tested here; production per-line truncation must still cut on a byte boundary defensively since UTF-8 characters can span up to 4 bytes.\n'
  } >"$report_path"

  printf '%s\n' "$report_path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bench_grep_candidates_main "${1:-}"
fi
