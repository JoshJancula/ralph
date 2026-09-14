#!/usr/bin/env bash
# Measure wall-clock latency of every output-shaping hook listed in docs/HOOKS.md.
#
# Runs each hook N times (default 5) against small fixtures under
# tests/fixtures/native-hook/ in three env states:
#   1) RALPH_MODE unset
#   2) RALPH_MODE=hybrid
#   3) RALPH_MODE=hybrid with every compaction channel on
#
# Prints a markdown table of mean milliseconds per call.
#
# Usage:
#   bash scripts/hook-latency.sh
#   bash scripts/hook-latency.sh -n 1
#   bash scripts/hook-latency.sh --hooks-doc path/to/HOOKS.md
#
# No new dependencies: bash + jq; python3 optional for higher-resolution timing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DOC="$REPO_ROOT/docs/HOOKS.md"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
N_RUNS=5

usage() {
  cat <<'EOF'
Usage: bash scripts/hook-latency.sh [options]

Options:
  -n N, --runs N        Iterations per hook per env state (default: 5)
  --hooks-doc PATH      Inventory markdown (default: docs/HOOKS.md)
  -h, --help            Show this help

Prints a markdown table of mean ms per call for every hook path listed in the
Hook inventory table. OpenCode's TypeScript plugin is listed as n/a (not a
stdin bash hook). Fixture payloads are derived from tests/fixtures/native-hook/.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -n | --runs)
      [[ $# -ge 2 ]] || { echo "hook-latency: $1 requires an argument" >&2; exit 2; }
      N_RUNS="$2"
      shift 2
      ;;
    --hooks-doc)
      [[ $# -ge 2 ]] || { echo "hook-latency: $1 requires an argument" >&2; exit 2; }
      HOOKS_DOC="$2"
      shift 2
      ;;
    *)
      echo "hook-latency: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$N_RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "hook-latency: -n must be a positive integer (got: $N_RUNS)" >&2
  exit 2
fi

[[ -f "$HOOKS_DOC" ]] || { echo "hook-latency: hooks doc not found: $HOOKS_DOC" >&2; exit 1; }
[[ -d "$FIXTURE_DIR" ]] || { echo "hook-latency: fixture dir not found: $FIXTURE_DIR" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "hook-latency: jq is required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Inventory parse: unique hook paths from the File column of Hook inventory.
# Relative siblings like `post-tool-mcp-compact.sh` resolve against the prior
# absolute path's directory. OpenCode `.ts` / `.mjs` collapse to one entry.
# ---------------------------------------------------------------------------
list_inventory_hooks() {
  local doc="$1"
  if command -v python3 >/dev/null 2>&1; then
    HOOKS_DOC="$doc" python3 - <<'PY'
import os, re
doc = open(os.environ["HOOKS_DOC"], encoding="utf-8").read()
m = re.search(r"## Hook inventory\n(.*?)(?=\n## )", doc, re.S)
if not m:
    raise SystemExit("hook inventory section not found")
paths = []
last_dir = None
for line in m.group(1).splitlines():
    if not line.startswith("|") or line.startswith("|---") or "File" in line.split("|")[1]:
        continue
    cell = line.split("|")[1]
    for raw in re.findall(r"`([^`]+)`", cell):
        token = raw.strip()
        if token in (".mjs", "/ .mjs"):
            continue
        if token.endswith(".mjs") and paths and paths[-1].endswith(".ts"):
            continue
        if "/" not in token and token.endswith(".sh") and last_dir:
            token = f"{last_dir}/{token}"
        if token.endswith((".sh", ".ts", ".mjs")):
            if token not in paths:
                paths.append(token)
            if "/" in token:
                last_dir = token.rsplit("/", 1)[0]
for p in paths:
    print(p)
PY
    return
  fi

  # awk/sed fallback without python3
  local in_inv=0 cell token last_dir="" resolved
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "## Hook inventory" ]]; then
      in_inv=1
      continue
    fi
    if [[ $in_inv -eq 1 && "$line" == "## "* ]]; then
      break
    fi
    [[ $in_inv -eq 1 ]] || continue
    [[ "$line" == \|* ]] || continue
    [[ "$line" == \|---* ]] && continue
    [[ "$line" == *"File"* && "$line" == *"Runtime"* ]] && continue
    cell="${line#|}"
    cell="${cell%%|*}"
    while [[ "$cell" == *\`* ]]; do
      cell="${cell#*\`}"
      token="${cell%%\`*}"
      cell="${cell#*\`}"
      token="${token#"${token%%[![:space:]]*}"}"
      token="${token%"${token##*[![:space:]]}"}"
      [[ "$token" == ".mjs" ]] && continue
      if [[ "$token" != */* && "$token" == *.sh && -n "$last_dir" ]]; then
        resolved="$last_dir/$token"
      else
        resolved="$token"
      fi
      case "$resolved" in
        *.sh | *.ts | *.mjs)
          printf '%s\n' "$resolved"
          if [[ "$resolved" == */* ]]; then
            last_dir="${resolved%/*}"
          fi
          ;;
      esac
    done
  done <"$doc" | awk 'NF && !seen[$0]++'
}

machine_class() {
  local sys mach model brand
  sys="$(uname -s 2>/dev/null || echo unknown)"
  mach="$(uname -m 2>/dev/null || echo unknown)"
  model=""
  brand=""
  if [[ "$sys" == "Darwin" ]]; then
    model="$(sysctl -n hw.model 2>/dev/null || true)"
    brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
  fi
  if [[ -n "$model" && -n "$brand" ]]; then
    printf '%s %s (%s / %s)\n' "$sys" "$mach" "$model" "$brand"
  elif [[ -n "$model" ]]; then
    printf '%s %s (%s)\n' "$sys" "$mach" "$model"
  else
    printf '%s %s\n' "$sys" "$mach"
  fi
}

# Timing helpers: prefer python3 perf_counter; else EPOCHREALTIME; else date.
time_hook_ms() {
  local hook="$1" payload="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$hook" "$payload" <<'PY'
import subprocess, sys, time
hook, payload = sys.argv[1], sys.argv[2]
with open(payload, "rb") as fh:
    t0 = time.perf_counter()
    subprocess.run(
        ["bash", hook],
        stdin=fh,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    print(f"{(time.perf_counter() - t0) * 1000.0:.3f}")
PY
    return
  fi
  local start end
  if [[ -n "${EPOCHREALTIME-}" ]]; then
    start="$EPOCHREALTIME"
    bash "$hook" <"$payload" >/dev/null 2>&1 || true
    end="$EPOCHREALTIME"
    awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f\n", (e - s) * 1000 }'
    return
  fi
  start="$(date +%s)"
  bash "$hook" <"$payload" >/dev/null 2>&1 || true
  end="$(date +%s)"
  awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f\n", (e - s) * 1000 }'
}

mean_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys; xs=[float(x) for x in sys.stdin if x.strip()]; print(f"{(sum(xs)/len(xs)):.1f}" if xs else "n/a")'
    return
  fi
  awk '{s+=$1; n++} END { if (n) printf "%.1f\n", s/n; else print "n/a" }'
}

# ---------------------------------------------------------------------------
# Payload builders: derive from fixtures; adapt event/tool for pre-tool hooks.
# ---------------------------------------------------------------------------
WORKDIR=""
PAYLOAD_DIR=""
TELEMETRY_LOG=""

cleanup() {
  [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ralph-hook-latency.XXXXXX")"
PAYLOAD_DIR="$WORKDIR/payloads"
TELEMETRY_LOG="$WORKDIR/telemetry.jsonl"
mkdir -p "$PAYLOAD_DIR" "$WORKDIR/workspace/.ralph-workspace"
: >"$TELEMETRY_LOG"

WS="$WORKDIR/workspace"
export RALPH_HOME="$REPO_ROOT"
export WORKSPACE="$WS"
export CLAUDE_PROJECT_DIR="$WS"
export RALPH_PROJECT_ROOT="$WS"
export RALPH_AGENT_WORKSPACE="$WS"
export RALPH_PLAN_WORKSPACE_ROOT="$WS/.ralph-workspace"
export RALPH_PLAN_KEY="hook-latency"
export RALPH_ARTIFACT_NS="hook-latency"

build_payloads() {
  local bash_fix="$FIXTURE_DIR/bash.json"
  local read_fix="$FIXTURE_DIR/read.json"
  local mcp_fix="$FIXTURE_DIR/mcp-ralph-proxy.json"

  # Claude / Codex PostToolUse Bash
  cp "$bash_fix" "$PAYLOAD_DIR/bash-post.json"

  # Claude PreToolUse Bash (rewrite / block-env uses Read pre)
  jq --arg cwd "$WS" \
    '.hook_event_name = "PreToolUse"
     | .cwd = $cwd
     | .tool_input.command = "echo hi"' \
    "$bash_fix" >"$PAYLOAD_DIR/bash-pre-claude.json"

  jq --arg cwd "$WS" \
    '.hook_event_name = "PreToolUse"
     | .tool_name = "Bash"
     | .cwd = $cwd
     | .tool_input.command = "echo hi"' \
    "$bash_fix" >"$PAYLOAD_DIR/bash-pre-codex.json"

  # Cursor preToolUse Shell
  jq --arg cwd "$WS" \
    '.hook_event_name = "preToolUse"
     | .tool_name = "Shell"
     | .cwd = $cwd
     | .workspace_roots = [$cwd]
     | .tool_input.command = "echo hi"' \
    "$bash_fix" >"$PAYLOAD_DIR/shell-pre-cursor.json"

  # Cursor postToolUse Shell telemetry
  jq --arg cwd "$WS" \
    '.hook_event_name = "postToolUse"
     | .tool_name = "Shell"
     | .cwd = $cwd
     | .workspace_roots = [$cwd]' \
    "$bash_fix" >"$PAYLOAD_DIR/shell-post-cursor.json"

  # Read / native-result / exploration
  cp "$read_fix" "$PAYLOAD_DIR/read-post.json"

  jq --arg cwd "$WS" \
    '.hook_event_name = "PreToolUse"
     | .cwd = $cwd
     | .tool_input.file_path = ($cwd + "/sample.txt")' \
    "$read_fix" >"$PAYLOAD_DIR/read-pre-claude.json"

  jq --arg cwd "$WS" \
    '.hook_event_name = "preToolUse"
     | .tool_name = "Read"
     | .cwd = $cwd
     | .workspace_roots = [$cwd]
     | .tool_input.path = ($cwd + "/sample.txt")
     | .tool_input.file_path = ($cwd + "/sample.txt")' \
    "$read_fix" >"$PAYLOAD_DIR/read-pre-cursor.json"

  jq --arg cwd "$WS" \
    '.hook_event_name = "postToolUse"
     | .tool_name = "Read"
     | .cwd = $cwd
     | .workspace_roots = [$cwd]' \
    "$read_fix" >"$PAYLOAD_DIR/read-post-cursor.json"

  # MCP compact + proxy-read handoff (path borrowed from read fixture)
  cp "$mcp_fix" "$PAYLOAD_DIR/mcp-post.json"

  jq -n --arg cwd "$WS" --arg path "$WS/sample.txt" \
    '{
      hook_event_name: "preToolUse",
      tool_name: "MCP:ralph_proxy_read",
      cwd: $cwd,
      workspace_roots: [$cwd],
      tool_input: {path: $path, file_path: $path}
    }' >"$PAYLOAD_DIR/mcp-read-pre.json"

  # afterShellExecution (shape from bash fixture command/output)
  jq --arg cwd "$WS" \
    '{
      command: (.tool_input.command // "echo hi"),
      output: (.tool_response.stdout // ""),
      duration: (.duration_ms // 10),
      cwd: $cwd,
      workspace_roots: [$cwd]
    }' \
    "$bash_fix" >"$PAYLOAD_DIR/after-shell.json"

  # Stop hooks: empty outstanding-job state fail-opens quickly
  printf '%s\n' '{"hook_event_name":"Stop"}' >"$PAYLOAD_DIR/stop-claude.json"
  printf '%s\n' '{"hook_event_name":"stop"}' >"$PAYLOAD_DIR/stop-cursor.json"

  printf 'sample\n' >"$WS/sample.txt"
}

payload_for_hook() {
  local rel="$1"
  case "$rel" in
    bundle/.claude/hooks/compact-bash-output.sh) printf '%s\n' "$PAYLOAD_DIR/bash-post.json" ;;
    bundle/.claude/hooks/rewrite-bash-command.sh) printf '%s\n' "$PAYLOAD_DIR/bash-pre-claude.json" ;;
    bundle/.claude/hooks/native-result-compact.sh) printf '%s\n' "$PAYLOAD_DIR/read-post.json" ;;
    bundle/.claude/hooks/block-env-reads.sh) printf '%s\n' "$PAYLOAD_DIR/read-pre-claude.json" ;;
    bundle/.claude/hooks/stop-continuation.sh) printf '%s\n' "$PAYLOAD_DIR/stop-claude.json" ;;
    bundle/.cursor/hooks/pre-tool-shell-policy.sh) printf '%s\n' "$PAYLOAD_DIR/shell-pre-cursor.json" ;;
    bundle/.cursor/hooks/pre-tool-exploration-policy.sh) printf '%s\n' "$PAYLOAD_DIR/read-pre-cursor.json" ;;
    bundle/.cursor/hooks/pre-tool-proxy-read-handoff.sh) printf '%s\n' "$PAYLOAD_DIR/mcp-read-pre.json" ;;
    bundle/.cursor/hooks/post-tool-shell-telemetry.sh) printf '%s\n' "$PAYLOAD_DIR/shell-post-cursor.json" ;;
    bundle/.cursor/hooks/post-tool-native-result-compact.sh) printf '%s\n' "$PAYLOAD_DIR/read-post-cursor.json" ;;
    bundle/.cursor/hooks/post-tool-mcp-compact.sh) printf '%s\n' "$PAYLOAD_DIR/mcp-post.json" ;;
    bundle/.cursor/hooks/after-shell-telemetry.sh) printf '%s\n' "$PAYLOAD_DIR/after-shell.json" ;;
    bundle/.cursor/hooks/stop-continuation.sh) printf '%s\n' "$PAYLOAD_DIR/stop-cursor.json" ;;
    bundle/.codex/hooks/pre-tool-bash-policy.sh) printf '%s\n' "$PAYLOAD_DIR/bash-pre-codex.json" ;;
    bundle/.codex/hooks/post-tool-bash-telemetry.sh) printf '%s\n' "$PAYLOAD_DIR/bash-post.json" ;;
    bundle/.codex/hooks/post-tool-native-result-compact.sh) printf '%s\n' "$PAYLOAD_DIR/read-post.json" ;;
    *) return 1 ;;
  esac
}

# Env state appliers. Compaction-channel set matches docs/HOOKS.md gates
# (not exploration steering).
clear_compaction_env() {
  unset RALPH_MODE \
    RALPH_BASH_COMPACT \
    RALPH_BASH_REWRITE \
    RALPH_NATIVE_RESULT_COMPACT \
    RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT \
    RALPH_NATIVE_SHELL_WRAPPER \
    RALPH_PROXY_SHELL_COMPACT \
    RALPH_CURSOR_MCP_HOOK_COMPACT \
    RALPH_COMPACT_GENERIC_FALLBACK \
    RALPH_BASH_TELEMETRY_LOG \
    RALPH_NATIVE_EXPLORATION_NUDGE \
    RALPH_MCP_TOOLS_ENABLED \
    RALPH_AGENT_TOOL_ACCESS \
    || true
}

apply_env_unset() {
  clear_compaction_env
}

apply_env_hybrid() {
  clear_compaction_env
  export RALPH_MODE=hybrid
}

apply_env_hybrid_all_compact() {
  clear_compaction_env
  export RALPH_MODE=hybrid
  export RALPH_BASH_COMPACT=1
  export RALPH_BASH_REWRITE=1
  export RALPH_NATIVE_RESULT_COMPACT=1
  export RALPH_NATIVE_SHELL_WRAPPER=1
  export RALPH_PROXY_SHELL_COMPACT=1
  export RALPH_CURSOR_MCP_HOOK_COMPACT=1
  export RALPH_COMPACT_GENERIC_FALLBACK=1
  export RALPH_BASH_TELEMETRY_LOG="$TELEMETRY_LOG"
}

measure_hook_mean() {
  local hook_abs="$1" payload="$2"
  local i sample
  local -a samples=()
  for ((i = 1; i <= N_RUNS; i++)); do
    sample="$(time_hook_ms "$hook_abs" "$payload")"
    samples+=("$sample")
  done
  printf '%s\n' "${samples[@]}" | mean_ms
}

build_payloads

HOOKS=()
while IFS= read -r h; do
  [[ -n "$h" ]] || continue
  HOOKS+=("$h")
done < <(list_inventory_hooks "$HOOKS_DOC")

if [[ ${#HOOKS[@]} -eq 0 ]]; then
  echo "hook-latency: no hooks parsed from $HOOKS_DOC" >&2
  exit 1
fi

STAMP="$(date +%Y-%m-%d 2>/dev/null || echo unknown-date)"
CLASS="$(machine_class)"

cat <<EOF
# Hook latency

- Date: $STAMP
- Machine: $CLASS
- Runs per cell: $N_RUNS
- Fixtures: \`tests/fixtures/native-hook/\`
- Env states: \`RALPH_MODE\` unset; \`RALPH_MODE=hybrid\`; \`RALPH_MODE=hybrid\` + every compaction channel on
  (\`RALPH_BASH_COMPACT\`, \`RALPH_BASH_REWRITE\`, \`RALPH_NATIVE_RESULT_COMPACT\`,
  \`RALPH_NATIVE_SHELL_WRAPPER\`, \`RALPH_PROXY_SHELL_COMPACT\` /
  \`RALPH_CURSOR_MCP_HOOK_COMPACT\`, \`RALPH_COMPACT_GENERIC_FALLBACK\`,
  \`RALPH_BASH_TELEMETRY_LOG\`)

| Hook | unset (ms) | hybrid (ms) | hybrid+all compact (ms) |
|------|------------|-------------|-------------------------|
EOF

for rel in "${HOOKS[@]}"; do
  # Prefer the inventory-relative path so Claude/Cursor/Codex siblings with the
  # same basename stay distinct table rows (and smoke tests can match each).
  label="$rel"
  if [[ "$rel" == *.ts || "$rel" == *.mjs ]]; then
    printf '| `%s` | n/a (OpenCode plugin) | n/a | n/a |\n' "$label"
    continue
  fi

  hook_abs="$REPO_ROOT/$rel"
  if [[ ! -f "$hook_abs" ]]; then
    printf '| `%s` | missing | missing | missing |\n' "$label"
    continue
  fi

  payload="$(payload_for_hook "$rel" || true)"
  if [[ -z "${payload:-}" || ! -f "${payload:-}" ]]; then
    printf '| `%s` | no-fixture | no-fixture | no-fixture |\n' "$label"
    continue
  fi

  apply_env_unset
  m_unset="$(measure_hook_mean "$hook_abs" "$payload")"

  apply_env_hybrid
  m_hybrid="$(measure_hook_mean "$hook_abs" "$payload")"

  apply_env_hybrid_all_compact
  m_all="$(measure_hook_mean "$hook_abs" "$payload")"

  printf '| `%s` | %s | %s | %s |\n' "$label" "$m_unset" "$m_hybrid" "$m_all"
done
