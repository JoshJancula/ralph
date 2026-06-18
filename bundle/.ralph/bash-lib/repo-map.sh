#!/usr/bin/env bash
# Aider-style repo-map digest: files plus key symbols, with mtime-keyed cache.

if [[ -n "${RALPH_REPO_MAP_LOADED:-}" ]]; then
  return
fi
RALPH_REPO_MAP_LOADED=1

_REPO_MAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _REPO_MAP_LIB_DIR

ralph_repo_map_workspace_root() {
  local workspace="${1:-${RALPH_MCP_WORKSPACE:-}}"
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}"
    return 0
  fi
  if [[ -n "$workspace" ]]; then
    printf '%s\n' "${workspace%/}/.ralph-workspace"
    return 0
  fi
  return 1
}

ralph_repo_map_cache_slug() {
  local search_root_abs="${1:-}"
  [[ -n "$search_root_abs" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$search_root_abs" | shasum -a 256 | awk '{print substr($1,1,16)}'
    return 0
  fi
  printf '%s' "$search_root_abs" | cksum | awk '{print $1}'
}

ralph_repo_map_cache_dir_for_root() {
  local workspace="${1:-}"
  local search_root_abs="${2:-}"
  local ws_root slug
  ws_root="$(ralph_repo_map_workspace_root "$workspace")" || return 1
  slug="$(ralph_repo_map_cache_slug "$search_root_abs")" || return 1
  printf '%s/repo-map/%s\n' "$ws_root" "$slug"
}

ralph_repo_map_file_is_binary() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 1
  if command -v file >/dev/null 2>&1; then
    file -b --mime-encoding "$file" 2>/dev/null | grep -q 'binary' && return 0
  fi
  LC_ALL=C grep -Iq . "$file" 2>/dev/null && return 1
  return 0
}

ralph_repo_map_is_git_work_tree() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 1
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

ralph_repo_map_enumerate_eligible_files() {
  local search_root="${1:-}"
  local out_file="${2:-}"
  local search_root_abs git_top abs_path repo_rel rel

  [[ -n "$search_root" && -n "$out_file" ]] || return 1
  if ! search_root_abs="$(cd "$search_root" && pwd -P 2>/dev/null)"; then
    return 1
  fi

  : >"$out_file"

  if ralph_repo_map_is_git_work_tree "$search_root_abs"; then
    git_top="$(git -C "$search_root_abs" rev-parse --show-toplevel 2>/dev/null)" || return 1
    git_top="${git_top%/}"
    while IFS= read -r -d '' repo_rel; do
      [[ -n "$repo_rel" ]] || continue
      abs_path="$git_top/$repo_rel"
      [[ -f "$abs_path" ]] || continue
      case "$abs_path" in
        "$search_root_abs"|"$search_root_abs"/*)
          if [[ "$abs_path" == "$search_root_abs" ]]; then
            rel="${repo_rel##*/}"
          else
            rel="${abs_path#$search_root_abs/}"
          fi
          ralph_repo_map_file_is_binary "$abs_path" && continue
          printf '%s\0' "$rel"
          ;;
      esac
    done >"$out_file" < <(git -C "$search_root_abs" ls-files -co --exclude-standard -z 2>/dev/null)
    return 0
  fi

  while IFS= read -r -d '' abs_path; do
    [[ -n "$abs_path" ]] || continue
    ralph_repo_map_file_is_binary "$abs_path" && continue
    rel="${abs_path#$search_root_abs/}"
    [[ -n "$rel" && "$rel" != "$abs_path" ]] || continue
    printf '%s\0' "$rel"
  done >"$out_file" < <(
    find "$search_root_abs" \
      \( \
        -name .git -o \
        -name node_modules -o \
        -name dist -o \
        -name build -o \
        -name target -o \
        -name .next -o \
        -name .cache -o \
        -name vendor \
      \) -prune -o \
      -type f -print0 2>/dev/null
  )
}

ralph_repo_map_write_manifest() {
  local search_root_abs="${1:-}"
  local manifest_file="${2:-}"
  local files_list="${3:-}"
  local relpath abs_path mtime

  [[ -n "$search_root_abs" && -n "$manifest_file" && -f "$files_list" ]] || return 1
  : >"$manifest_file"
  while IFS= read -r -d '' relpath; do
    [[ -n "$relpath" ]] || continue
    abs_path="$search_root_abs/$relpath"
    [[ -f "$abs_path" ]] || continue
    mtime="$(stat -f '%m' "$abs_path" 2>/dev/null || stat -c '%Y' "$abs_path" 2>/dev/null || printf '0')"
    printf '%s\t%s\n' "$relpath" "$mtime"
  done <"$files_list" | sort >"$manifest_file"
}

ralph_repo_map_manifest_is_stale() {
  local search_root_abs="${1:-}"
  local manifest_file="${2:-}"
  local files_list="${3:-}"
  local relpath abs_path current_mtime stored_mtime

  [[ -n "$search_root_abs" && -f "$manifest_file" && -f "$files_list" ]] || return 0

  while IFS= read -r -d '' relpath; do
    [[ -n "$relpath" ]] || continue
    abs_path="$search_root_abs/$relpath"
    [[ -f "$abs_path" ]] || return 0
    current_mtime="$(stat -f '%m' "$abs_path" 2>/dev/null || stat -c '%Y' "$abs_path" 2>/dev/null || printf '0')"
    stored_mtime="$(awk -F '\t' -v path="$relpath" '$1 == path { print $2; found=1; exit } END { if (!found) print "" }' "$manifest_file")"
    if [[ -z "$stored_mtime" || "$stored_mtime" != "$current_mtime" ]]; then
      return 0
    fi
  done <"$files_list"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    relpath="${line%%$'\t'*}"
    [[ -n "$relpath" ]] || continue
    if ! grep -Fqx "$relpath" < <(tr '\0' '\n' <"$files_list"); then
      return 0
    fi
  done <"$manifest_file"

  return 1
}

ralph_repo_map_python_helper() {
  printf '%s/../python/repo_map.py\n' "$_REPO_MAP_LIB_DIR"
}

ralph_repo_map_format_with_python() {
  local mode="${1:-}"
  local input_file="${2:-}"
  local output_file="${3:-}"
  local helper

  [[ -n "$mode" && -f "$input_file" && -n "$output_file" ]] || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  helper="$(ralph_repo_map_python_helper)"
  [[ -f "$helper" ]] || return 1
  python3 "$helper" "$mode" <"$input_file" >"$output_file"
}

ralph_repo_map_format_with_awk() {
  local input_mode="${1:-}"
  local input_file="${2:-}"
  local output_file="${3:-}"
  [[ -f "$input_file" && -n "$output_file" ]] || return 1

  if [[ "$input_mode" == "regex-payload" ]]; then
    awk '
      function flush(path,   i) {
        if (path == "") return
        print path ":"
        for (i = 1; i <= sym_count; i++) print "  " symbols[i]
      }
      function add_symbol(sym) {
        for (i = 1; i <= sym_count; i++) if (symbols[i] == sym) return
        sym_count++
        symbols[sym_count] = sym
      }
      function parse_line(line,   m) {
        if (match(line, /^[[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?(function|class|interface|type|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_$]*)/, m))
          return m[4]
        if (match(line, /^[[:space:]]*class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)/, m))
          return "class " m[1]
        if (match(line, /^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)/, m))
          return "def " m[2]
        if (match(line, /^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)/, m))
          return "function " m[2]
        return ""
      }
      BEGIN { path = ""; sym_count = 0 }
      /^@@FILE@@/ {
        flush(path)
        path = substr($0, 9)
        sym_count = 0
        delete symbols
        next
      }
      {
        sym = parse_line($0)
        if (sym != "") add_symbol(sym)
      }
      END { flush(path) }
    ' "$input_file" >"$output_file"
    return 0
  fi

  awk '
    function flush(path,   i) {
      if (path == "") return
      print path ":"
      for (i = 1; i <= sym_count; i++) print "  " symbols[i]
    }
    function add_symbol(sym) {
      for (i = 1; i <= sym_count; i++) if (symbols[i] == sym) return
      sym_count++
      symbols[sym_count] = sym
    }
    function parse_rg(line,   m, text) {
      n = split(line, parts, ":")
      if (n < 3) return
      path = parts[1]
      text = substr(line, length(parts[1]) + length(parts[2]) + 3)
      if (match(text, /(function|class|interface|type|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_$]*)/, m))
        return m[2]
      if (match(text, /class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)/, m))
        return "class " m[1]
      if (match(text, /def[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)/, m))
        return "def " m[1]
      return ""
    }
    BEGIN { path = ""; sym_count = 0 }
    {
      sym = parse_rg($0)
      if (sym == "") next
      split($0, parts, ":")
      file = parts[1]
      if (file != path) {
        flush(path)
        path = file
        sym_count = 0
        delete symbols
      }
      add_symbol(sym)
    }
    END { flush(path) }
  ' "$input_file" >"$output_file"
}

ralph_repo_map_build_regex_payload() {
  local search_root_abs="${1:-}"
  local files_list="${2:-}"
  local payload_file="${3:-}"
  local relpath abs_path

  [[ -n "$search_root_abs" && -f "$files_list" && -n "$payload_file" ]] || return 1
  : >"$payload_file"
  while IFS= read -r -d '' relpath; do
    [[ -n "$relpath" ]] || continue
    abs_path="$search_root_abs/$relpath"
    [[ -f "$abs_path" ]] || continue
    printf '@@FILE@@%s\n' "$relpath" >>"$payload_file"
    cat "$abs_path" >>"$payload_file"
    printf '\n' >>"$payload_file"
  done <"$files_list"
}

ralph_repo_map_extract_with_ctags() {
  local search_root_abs="${1:-}"
  local files_list="${2:-}"
  local raw_file="${3:-}"
  local relpath abs_path args=()

  [[ -n "$search_root_abs" && -f "$files_list" && -n "$raw_file" ]] || return 1
  command -v ctags >/dev/null 2>&1 || return 1
  : >"$raw_file"
  while IFS= read -r -d '' relpath; do
    [[ -n "$relpath" ]] || continue
    abs_path="$search_root_abs/$relpath"
    [[ -f "$abs_path" ]] || continue
    args+=("$abs_path")
  done <"$files_list"
  [[ ${#args[@]} -gt 0 ]] || return 1
  if ctags --help 2>&1 | grep -q 'output-format'; then
    ctags --output-format=json --fields=+n -f - "${args[@]}" >"$raw_file" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

ralph_repo_map_extract_with_rg() {
  local search_root_abs="${1:-}"
  local files_list="${2:-}"
  local raw_file="${3:-}"
  local pattern relpath abs_path line

  [[ -n "$search_root_abs" && -f "$files_list" && -n "$raw_file" ]] || return 1
  command -v rg >/dev/null 2>&1 || return 1
  pattern='^(export[[:space:]]+)?(async[[:space:]]+)?(function|class|interface|type|enum)[[:space:]]+|[[:space:]]*(async[[:space:]]+)?def[[:space:]]+|^[[:space:]]*class[[:space:]]+|^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)'
  : >"$raw_file"
  while IFS= read -r -d '' relpath; do
    [[ -n "$relpath" ]] || continue
    abs_path="$search_root_abs/$relpath"
    [[ -f "$abs_path" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf '%s:%s\n' "$relpath" "$line"
    done < <(rg --no-heading -n -- "$pattern" "$abs_path" 2>/dev/null || true)
  done <"$files_list" >>"$raw_file"
  [[ -s "$raw_file" ]] || return 1
}

ralph_repo_map_digest_has_content() {
  local digest_file="${1:-}"
  [[ -f "$digest_file" && -s "$digest_file" ]] || return 1
  grep -q ':' "$digest_file" 2>/dev/null
}

ralph_repo_map_build_digest() {
  local search_root_abs="${1:-}"
  local files_list="${2:-}"
  local digest_file="${3:-}"
  local backend="${4:-}"
  local raw_file payload_file tmp_digest

  [[ -n "$search_root_abs" && -f "$files_list" && -n "$digest_file" ]] || return 1
  raw_file="$(mktemp)"
  payload_file="$(mktemp)"
  tmp_digest="$(mktemp)"

  if [[ "$backend" == "ctags" || -z "$backend" ]]; then
    if ralph_repo_map_extract_with_ctags "$search_root_abs" "$files_list" "$raw_file"; then
      if ralph_repo_map_format_with_python "ctags" "$raw_file" "$tmp_digest" \
        && ralph_repo_map_digest_has_content "$tmp_digest"; then
        mv "$tmp_digest" "$digest_file"
        rm -f "$raw_file" "$payload_file" "$tmp_digest"
        printf '%s\n' "ctags"
        return 0
      fi
    fi
  fi

  if [[ "$backend" == "rg" || -z "$backend" ]]; then
    if ralph_repo_map_extract_with_rg "$search_root_abs" "$files_list" "$raw_file"; then
      if ralph_repo_map_format_with_python "rg" "$raw_file" "$tmp_digest" \
        && ralph_repo_map_digest_has_content "$tmp_digest"; then
        mv "$tmp_digest" "$digest_file"
        rm -f "$raw_file" "$payload_file" "$tmp_digest"
        printf '%s\n' "rg"
        return 0
      fi
      if ralph_repo_map_format_with_awk "rg" "$raw_file" "$tmp_digest" \
        && ralph_repo_map_digest_has_content "$tmp_digest"; then
        mv "$tmp_digest" "$digest_file"
        rm -f "$raw_file" "$payload_file" "$tmp_digest"
        printf '%s\n' "rg-awk"
        return 0
      fi
    fi
  fi

  ralph_repo_map_build_regex_payload "$search_root_abs" "$files_list" "$payload_file" || {
    rm -f "$raw_file" "$payload_file" "$tmp_digest"
    return 1
  }
  if ralph_repo_map_format_with_python "regex" "$payload_file" "$tmp_digest" \
    && ralph_repo_map_digest_has_content "$tmp_digest"; then
    mv "$tmp_digest" "$digest_file"
    rm -f "$raw_file" "$payload_file" "$tmp_digest"
    printf '%s\n' "regex"
    return 0
  fi
  if ralph_repo_map_format_with_awk "regex-payload" "$payload_file" "$tmp_digest" \
    && ralph_repo_map_digest_has_content "$tmp_digest"; then
    mv "$tmp_digest" "$digest_file"
    rm -f "$raw_file" "$payload_file" "$tmp_digest"
    printf '%s\n' "regex-awk"
    return 0
  fi

  rm -f "$raw_file" "$payload_file" "$tmp_digest"
  return 1
}

ralph_repo_map_emit_digest() {
  local workspace="${1:-}"
  local search_root="${2:-.}"
  local max_files="${3:-0}"
  local search_root_abs cache_dir manifest_file digest_file files_list backend rebuilt=0
  local relpath count=0 limited_files

  if ! search_root_abs="$(cd "$workspace/$search_root" 2>/dev/null && pwd -P)"; then
    if ! search_root_abs="$(cd "$search_root" 2>/dev/null && pwd -P)"; then
      return 1
    fi
  fi

  cache_dir="$(ralph_repo_map_cache_dir_for_root "$workspace" "$search_root_abs")" || return 1
  mkdir -p "$cache_dir"
  manifest_file="$cache_dir/manifest.tsv"
  digest_file="$cache_dir/digest.txt"
  files_list="$(mktemp)"
  limited_files="$(mktemp)"

  ralph_repo_map_enumerate_eligible_files "$search_root_abs" "$files_list" || {
    rm -f "$files_list" "$limited_files"
    return 1
  }

  if [[ "$max_files" =~ ^[0-9]+$ ]] && [[ "$max_files" -gt 0 ]]; then
    while IFS= read -r -d '' relpath; do
      [[ -n "$relpath" ]] || continue
      count=$((count + 1))
      if [[ "$count" -gt "$max_files" ]]; then
        break
      fi
      printf '%s\0' "$relpath"
    done <"$files_list" >"$limited_files"
    mv "$limited_files" "$files_list"
  else
    rm -f "$limited_files"
  fi

  if [[ -f "$manifest_file" && -f "$digest_file" ]] \
    && ! ralph_repo_map_manifest_is_stale "$search_root_abs" "$manifest_file" "$files_list"; then
    cat "$digest_file"
    rm -f "$files_list"
    return 0
  fi

  rebuilt=1
  backend="$(ralph_repo_map_build_digest "$search_root_abs" "$files_list" "$digest_file")" || {
    rm -f "$files_list"
    return 1
  }
  ralph_repo_map_write_manifest "$search_root_abs" "$manifest_file" "$files_list"
  printf '{"rebuilt":true,"backend":"%s"}\n' "$backend" >"$cache_dir/meta.json"
  cat "$digest_file"
  rm -f "$files_list"
}

ralph_repo_map_cache_meta_json() {
  local workspace="${1:-}"
  local search_root="${2:-.}"
  local search_root_abs cache_dir

  if ! search_root_abs="$(cd "$workspace/$search_root" 2>/dev/null && pwd -P)"; then
    if ! search_root_abs="$(cd "$search_root" 2>/dev/null && pwd -P)"; then
      return 1
    fi
  fi
  cache_dir="$(ralph_repo_map_cache_dir_for_root "$workspace" "$search_root_abs")" || return 1
  if [[ -f "$cache_dir/meta.json" ]]; then
    cat "$cache_dir/meta.json"
    return 0
  fi
  printf '{}\n'
}
