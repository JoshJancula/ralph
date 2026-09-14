#!/usr/bin/env bash
# Bats suite file discovery for scripts/run-bats.sh

# Emit repo-relative paths (tests/bats/...), one per line.
# Recurses into all subdirs via find; excludes tests/bats/local/ (operator-only).
ralph_bats_suite_files() {
  local repo_root="${1:?repo root required}"
  local f rel
  while IFS= read -r f; do
    rel="${f#"$repo_root"/}"
    printf '%s\n' "$rel"
  done < <(find "$repo_root/tests/bats" -name "*.bats" -not -path "*/local/*" -type f | LC_ALL=C sort)
}

# Emit the repo-relative paths listed under one array of tests/bats/tiers.json
# ("slow" or "acceptance"). The manifest is a flat list of
# `{ "file": "...", ... }` objects grouped under those two keys, so an awk
# extraction is enough; this deliberately avoids depending on jq or python3 so
# that tier selection works in any environment that can run the suite at all.
ralph_bats_manifest_files() {
  local repo_root="${1:?repo root required}"
  local section="${2:?section required}"
  local manifest="$repo_root/tests/bats/tiers.json"
  [[ -f "$manifest" ]] || return 0
  awk -v want="$section" '
    /"(slow|acceptance|measured)"[[:space:]]*:[[:space:]]*\[/ {
      if ($0 ~ /"acceptance"/) { section = "acceptance" }
      else if ($0 ~ /"measured"/) { section = "measured" }
      else { section = "slow" }
      next
    }
    section == want && match($0, /"file"[[:space:]]*:[[:space:]]*"[^"]*"/) {
      line = substr($0, RSTART, RLENGTH)
      sub(/.*"file"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/"$/, "", line)
      print line
    }
  ' "$manifest" | LC_ALL=C sort -u
}

# Files excluded from the fast tier: everything the manifest marks slow or
# acceptance.
ralph_bats_nonfast_files() {
  local repo_root="${1:?repo root required}"
  {
    ralph_bats_manifest_files "$repo_root" slow
    ralph_bats_manifest_files "$repo_root" acceptance
  } | LC_ALL=C sort -u
}

# Emit the suite files for a tier:
#   fast       everything the manifest marks neither slow nor acceptance
#   slow       the manifest's "slow" files
#   acceptance the manifest's "acceptance" files (heavy end-to-end replays)
#   all        the whole suite
# fast/slow/acceptance partition "all" exactly. Unknown tiers are a caller error.
ralph_bats_tier_files() {
  local repo_root="${1:?repo root required}"
  local tier="${2:?tier required}"
  local all selected

  all="$(ralph_bats_suite_files "$repo_root")"
  case "$tier" in
    all)
      printf '%s\n' "$all"
      return 0
      ;;
    fast)
      selected="$(ralph_bats_nonfast_files "$repo_root")"
      if [[ -z "$selected" ]]; then
        # No manifest (or an empty one): never silently drop coverage.
        printf '%s\n' "$all"
        return 0
      fi
      LC_ALL=C comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$selected")
      return 0
      ;;
    slow | acceptance)
      selected="$(ralph_bats_manifest_files "$repo_root" "$tier")"
      [[ -n "$selected" ]] || return 0
      # Intersect with what exists so a stale manifest entry cannot invent a path.
      LC_ALL=C comm -12 <(printf '%s\n' "$all") <(printf '%s\n' "$selected")
      return 0
      ;;
    *)
      echo "ralph_bats_tier_files: unknown tier: $tier" >&2
      return 1
      ;;
  esac
}

# --- Fast-tier cost budget --------------------------------------------------
#
# tests/bats/tiers.json carries a checked-in timing baseline under "measured".
# The fast tier is the set CI gates every push on, so a file the baseline
# records as expensive must not sit in it. Enforcing that here keeps the check
# a cheap manifest lookup: run-bats.sh must never have to time the suite to
# decide what to run. Re-measuring is scripts/capture-bats-timing.sh's job.
#
# Deliberately awk-only, like the rest of this file, so tier selection keeps
# working in any environment that can run the suite at all.

# Emit "testSeconds<TAB>fileSeconds" from tiers.json "fastBudget", or the
# built-in defaults when the manifest does not pin them.
ralph_bats_fast_budget() {
  local repo_root="${1:?repo root required}"
  local manifest="$repo_root/tests/bats/tiers.json"
  local test_s=60 file_s=60
  if [[ -f "$manifest" ]]; then
    local found
    found="$(awk '
      /"fastBudget"[[:space:]]*:/ { inb = 1 }
      inb && match($0, /"testSeconds"[[:space:]]*:[[:space:]]*[0-9.]+/) {
        v = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", v); t = v
      }
      inb && match($0, /"fileSeconds"[[:space:]]*:[[:space:]]*[0-9.]+/) {
        v = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", v); f = v
      }
      inb && /}/ { inb = 0 }
      END { if (t != "" && f != "") printf "%s\t%s\n", t, f }
    ' "$manifest")"
    [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
  fi
  printf '%s\t%s\n' "$test_s" "$file_s"
}

# Emit "file<TAB>seconds<TAB>maxTestSeconds" for each entry of the checked-in
# "measured" baseline. Absent baseline data is not an error: an unmeasured file
# is simply not enforced against.
ralph_bats_measured_rows() {
  local repo_root="${1:?repo root required}"
  local manifest="$repo_root/tests/bats/tiers.json"
  [[ -f "$manifest" ]] || return 0
  awk '
    /"(slow|acceptance|measured)"[[:space:]]*:[[:space:]]*\[/ {
      section = ($0 ~ /"measured"/) ? "measured" : "other"
      next
    }
    section == "measured" && /"file"[[:space:]]*:/ {
      f = ""; s = ""; m = ""
      if (match($0, /"file"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        f = substr($0, RSTART, RLENGTH)
        sub(/.*"file"[[:space:]]*:[[:space:]]*"/, "", f); sub(/"$/, "", f)
      }
      if (match($0, /"seconds"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
        s = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", s)
      }
      if (match($0, /"maxTestSeconds"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
        m = substr($0, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", m)
      }
      if (f != "") printf "%s\t%s\t%s\n", f, (s == "" ? 0 : s), (m == "" ? 0 : m)
    }
  ' "$manifest"
}

# Emit one line per fast-tier file the baseline records as over budget:
#   "<file>\t<reason>"
# Empty output means the fast tier is within budget.
ralph_bats_fast_budget_violations() {
  local repo_root="${1:?repo root required}"
  local budget test_s file_s
  budget="$(ralph_bats_fast_budget "$repo_root")"
  IFS=$'\t' read -r test_s file_s <<<"$budget"

  local fast_list measured
  fast_list="$(ralph_bats_tier_files "$repo_root" fast)" || return 0
  measured="$(ralph_bats_measured_rows "$repo_root")"
  [[ -n "$measured" ]] || return 0

  awk -F'\t' -v ts="$test_s" -v fs="$file_s" '
    NR == FNR { fast[$0] = 1; next }
    ($1 in fast) {
      if ($3 + 0 >= ts + 0) {
        printf "%s\ttest %.1fs >= %.0fs budget\n", $1, $3, ts
      } else if ($2 + 0 >= fs + 0) {
        printf "%s\tfile %.1fs >= %.0fs aggregate budget\n", $1, $2, fs
      }
    }
  ' <(printf '%s\n' "$fast_list") <(printf '%s\n' "$measured")
}
