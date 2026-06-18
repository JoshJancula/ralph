#!/usr/bin/env bash
set -euo pipefail

# Build the Ralph benchmark report: aggregate per-run usage summaries into
# token/compaction figures across optimization paths, then render Markdown (or JSON).
#
# Data flow (you do not have to run these by hand -- this wrapper does it):
#   .ralph-workspace/logs/<plan>/plan-usage-summary.json
#     -> ralph-benchmark-report.py   (aggregate into one report JSON)
#     -> render-benchmark-markdown.py (render that JSON as Markdown)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DOCS_DEFAULT="$SCRIPT_DIR/../../docs/BENCHMARKS.md"

print_usage() {
  cat <<'EOU'
Usage: benchmark-report.sh [OPTIONS]

Aggregates plan-usage-summary.json files into the Ralph benchmark report.

Options:
  --workspace <path>   Workspace root (default: current directory; use --full to search $HOME).
  --logs-dir <path>    Directory containing usage logs (repeatable).
                        Default: <workspace>/.ralph-workspace/logs when the current
                        directory is or directly contains a .ralph-workspace; otherwise
                        all registered workspaces with --full or when run outside a
                        workspace.
  --plan <key-or-path> Filter report to matching plan(s) (repeatable). Matches log-dir
                       basename, summary plan_key, or plan file basename. If the value
                       looks like a path or ends in .md, it is normalized to the basename
                       without .md extension before matching.
  --format markdown|json   Output format (default: markdown).
  --write-doc          Also write the Markdown report to the doc file (implies markdown).
  --no-doc             Do not write any doc file (default).
  --output <path>      Doc file to write with --write-doc (default: docs/BENCHMARKS.md).
  --full               Search all registered workspaces instead of the current one.
  -h, --help           Show this message.
EOU
}

workspace=""
logs_dirs=()
seen_logs_dirs=$'\n'
plan_filters=()
format="markdown"
full=0
write_doc=0
output="$REPO_DOCS_DEFAULT"

add_logs_dir() {
  local logs_dir="$1"
  if [[ -z "$logs_dir" || ! -d "$logs_dir" ]]; then
    return
  fi
  case "$seen_logs_dirs" in
    *$'\n'"$logs_dir"$'\n'*)
      return
      ;;
  esac
  seen_logs_dirs+="$logs_dir"$'\n'
  logs_dirs+=("$logs_dir")
}

# Detect a workspace at the current directory level only: PWD itself is a
# .ralph-workspace directory, or PWD has a .ralph-workspace child. This keeps
# `ralph benchmark` scoped like `.claude` / `.ralph-workspace` discovery.
find_local_logs_dir() {
  local dir="${1:-$PWD}"
  [[ -d "$dir" ]] || return 1
  dir="$(cd "$dir" && pwd)"
  local base
  base="$(basename "$dir")"
  if [[ "$base" == ".ralph-workspace" ]]; then
    printf '%s\n' "$dir/logs"
    return 0
  fi
  if [[ -d "$dir/.ralph-workspace" ]]; then
    printf '%s\n' "$dir/.ralph-workspace/logs"
    return 0
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --workspace)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --workspace requires a workspace path." >&2
        exit 1
      fi
      workspace="$2"
      shift 2
      ;;
    --logs-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --logs-dir requires a directory path." >&2
        exit 1
      fi
      logs_dirs+=("$2")
      shift 2
      ;;
    --plan)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --plan requires a key or path." >&2
        exit 1
      fi
      # Normalize: if it looks like a path or ends in .md, reduce to basename without .md
      plan_value="$2"
      if [[ "$plan_value" == */* ]] || [[ "$plan_value" == *.md ]]; then
        # It looks like a path
        plan_value="$(basename "$plan_value")"
        # Remove .md extension if present
        plan_value="${plan_value%.md}"
      fi
      plan_filters+=("$plan_value")
      shift 2
      ;;
    --format)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --format requires markdown or json." >&2
        exit 1
      fi
      case "$2" in
        markdown|json)
          format="$2"
          ;;
        *)
          echo "Error: --format must be markdown or json." >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    --write-doc)
      write_doc=1
      format="markdown"
      shift
      ;;
    --no-doc)
      write_doc=0
      shift
      ;;
    --output)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --output requires a file path." >&2
        exit 1
      fi
      output="$2"
      shift 2
      ;;
    --full)
      full=1
      shift
      ;;
    *)
      echo "Error: unknown argument $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$workspace" ]]; then
  if [[ "$full" -eq 1 ]]; then
    workspace="$HOME"
  else
    workspace="$PWD"
  fi
fi

workspace="$(cd "$workspace" && pwd)"

_registry_py="$SCRIPT_DIR/python/workspace-registry.py"

_registry_paths() {
  local registry_file
  if [[ -n "${RALPH_WORKSPACES_FILE:-}" ]]; then
    registry_file="$RALPH_WORKSPACES_FILE"
  else
    local config_home="${XDG_CONFIG_HOME:-}"
    if [[ -z "$config_home" && -n "${HOME:-}" ]]; then
      config_home="$HOME/.config"
    fi
    registry_file="$config_home/ralph/workspaces.json"
  fi
  if [[ -f "$registry_file" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$_registry_py" paths "$registry_file" 2>/dev/null
  fi
}

collect_registry_logs_dirs() {
  while IFS= read -r ws_path; do
    [[ -z "$ws_path" ]] && continue
    add_logs_dir "${ws_path}/.ralph-workspace/logs"
  done < <(_registry_paths)
}

collect_home_logs_dirs() {
  local home_dir="${HOME:-}"
  [[ -z "$home_dir" ]] && return
  while IFS= read -r ws_dir; do
    add_logs_dir "${ws_dir}/logs"
  done < <(find "$home_dir" -maxdepth 5 \
    \( -path '*/.git' -o -path '*/node_modules' \) -prune -o \
    -type d -name '.ralph-workspace' -print 2>/dev/null | sort)
}

# Build logs_dirs if none were explicitly provided.
if [[ ${#logs_dirs[@]} -eq 0 ]]; then
  _local_logs_dir=""
  if [[ "$full" -eq 0 ]]; then
    _local_logs_dir="$(find_local_logs_dir "$workspace" 2>/dev/null)" || true
  fi
  if [[ -n "$_local_logs_dir" ]]; then
    add_logs_dir "$_local_logs_dir"
  else
    collect_registry_logs_dirs
    collect_home_logs_dirs
    if [[ ${#logs_dirs[@]} -eq 0 ]]; then
      add_logs_dir "${workspace}/.ralph-workspace/logs"
    fi
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found on PATH; the benchmark report needs python3." >&2
  exit 1
fi

# Collect every plan-usage-summary.json under the discovered log directories.
summaries=()
seen_summaries=$'\n'
for d in "${logs_dirs[@]}"; do
  while IFS= read -r summary; do
    [[ -z "$summary" ]] && continue
    case "$seen_summaries" in
      *$'\n'"$summary"$'\n'*) continue ;;
    esac
    seen_summaries+="$summary"$'\n'
    summaries+=("$summary")
  done < <(find "$d" -type f -name 'plan-usage-summary.json' 2>/dev/null | sort)
done

if [[ ${#summaries[@]} -eq 0 ]]; then
  echo "No plan-usage-summary.json files found. Run a plan first (ralph run --plan ...), then retry." >&2
  echo "Searched: ${logs_dirs[*]:-<none>}" >&2
  exit 0
fi

# If plan filters were provided, filter the summaries.
if [[ ${#plan_filters[@]} -gt 0 ]]; then
  filtered_summaries=()
  available_plan_keys=()

  for summary in "${summaries[@]}"; do
    log_dir_basename="$(basename "$(dirname "$summary")")"
    matched=0

    # Check if log_dir_basename matches any filter
    for filter in "${plan_filters[@]}"; do
      if [[ "$log_dir_basename" == "$filter" ]]; then
        matched=1
        break
      fi
    done

    # If not matched by log dir, check plan_key and plan path via python3
    if [[ $matched -eq 0 ]]; then
      # Use python3 to read plan_key and plan from the summary JSON
      json_match="$(python3 -c "
import json, sys, os
try:
  with open('$summary') as f:
    doc = json.load(f)
  plan_key = str(doc.get('plan_key', ''))
  plan_path = str(doc.get('plan', ''))
  plan_basename = os.path.basename(plan_path).replace('.md', '') if plan_path else ''
  print(plan_key)
  print(plan_basename)
except Exception:
  pass
" 2>/dev/null || echo "")"

      if [[ -n "$json_match" ]]; then
        plan_key="$(echo "$json_match" | sed -n '1p')"
        plan_basename="$(echo "$json_match" | sed -n '2p')"

        for filter in "${plan_filters[@]}"; do
          if [[ "$plan_key" == "$filter" ]] || [[ "$plan_basename" == "$filter" ]]; then
            matched=1
            break
          fi
        done
      fi
    fi

    if [[ $matched -eq 1 ]]; then
      filtered_summaries+=("$summary")
    else
      # Collect available plan keys for error message
      log_dir_basename="$(basename "$(dirname "$summary")")"
      json_keys="$(python3 -c "
import json
try:
  with open('$summary') as f:
    doc = json.load(f)
  plan_key = str(doc.get('plan_key', ''))
  if plan_key:
    print(plan_key)
except Exception:
  pass
" 2>/dev/null || echo "")"

      if [[ -z "$json_keys" ]]; then
        json_keys="$log_dir_basename"
      fi
      available_plan_keys+=("$json_keys")
    fi
  done

  if [[ ${#filtered_summaries[@]} -eq 0 ]]; then
    echo "Error: --plan filters did not match any summaries." >&2
    echo "Requested: ${plan_filters[*]}" >&2
    if [[ ${#available_plan_keys[@]} -gt 0 ]]; then
      echo "Available plan keys:" >&2
      for key in "${available_plan_keys[@]}"; do
        if [[ -n "$key" ]]; then
          echo "  $key" >&2
        fi
      done
    fi
    exit 1
  fi

  summaries=("${filtered_summaries[@]}")
fi

report_json="$(python3 "$SCRIPT_DIR/python/ralph-benchmark-report.py" "${summaries[@]}")"

if [[ "$format" == "json" ]]; then
  printf '%s\n' "$report_json"
  exit 0
fi

markdown="$(printf '%s' "$report_json" | python3 "$SCRIPT_DIR/python/render-benchmark-markdown.py" /dev/stdin)"
printf '%s\n' "$markdown"

if [[ "$write_doc" -eq 1 ]]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$markdown" >"$output"
  echo "Wrote benchmark report to $output" >&2
fi
