#!/usr/bin/env bash

if [[ -n "${RALPH_PLAN_TODO_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_PLAN_TODO_LIB_LOADED=1

# Public interface:
#   plan_normalize_path, plan_log_basename -- path and safe log-stem helpers.
#   plan_format_is_yaml -- true when format is YAML frontmatter ('yaml' or legacy alias 'cursor').
#   plan_format_display -- canonical plan-format label for logs and user-facing output.
#   plan_detect_format -- detect 'default' (markdown) or 'yaml' (YAML frontmatter) format.
#   plan_open_todo_body -- strip markdown checkbox prefix from an open task line.
#   get_next_todo -- default markdown: "file_line|full block" for first open "- [ ]" task, where file_line is the checkbox line; yaml frontmatter: "ordinal|id|content" (id empty when absent).
#   count_todos -- prints "done total" counts; yaml frontmatter plans treat completed/complete/done (case-insensitive) as done.
#   plan_todo_ordinal_at_line -- 1-based checklist index at a given file line (default markdown only).
#   plan_todo_ordinal_for_next -- 1-based task index for status UI: same as ordinal-at-line for default plans;
#     for yaml frontmatter plans, get_next_todo's first field is already the YAML todo ordinal.
#   plan_todo_implies_operator_dialog -- true when wording should block on operator (pending-human).
#   plan_todo_risk_classify -- classify a TODO as manual_gate, verification_gate, destructive_gate, implementation_gate, or normal.
#   plan_todo_extract_verification_commands -- emit command evidence candidates for verification-gate TODOs.
#   plan_todo_hash -- stable content hash used for manual ack scoping.
#   plan_todo_autonomous_evidence_present -- true when the current invocation already includes a structured autonomous verification signal.
#   plan_pipeline_todo_metadata_json -- pipeline-format raw TODO metadata JSON helper.
#   plan_pipeline_effective_metadata_json -- pipeline-format effective TODO metadata JSON helper.
#   plan_structured_todo_metadata_json -- compatibility wrapper for pipeline-format raw TODO metadata.
#   plan_structured_effective_metadata_json -- compatibility wrapper for pipeline-format effective TODO metadata.
#   plan_pipeline_validate_plan -- validates yaml-frontmatter plans (pipeline and standard todos).
#   plan_workflow_validate -- validates a reusable workflow source (kind: workflow, mode: sequential|dependency; legacy engine: accepted with warning).
#   plan_workflow_instantiate -- materializes workflow + task into an ordinary plan before engine compilation.
#   plan_provided_input_extract -- pure supplied-plan extractor (format, TODO counts, overview,
#     header runtime/model, SHA-256, task provenance); never writes files.
#   plan_provided_input_manifest_json -- pure transform from extract + copied path into
#     workflow-input-plan.schema.json version-1 manifest JSON (still no writes).
#   plan_provided_input_validate_manifest -- validate a manifest file against the schema.
#   plan_provided_input_to_run_metadata -- pure transform from a version-1 input manifest
#     plus absolute manifest path into the run.json inputPlan object.
#   plan_reopen_todo_at_line -- flip [x] back to [ ] at a line.
#   plan_reopen_todo_yaml -- reopen a yaml frontmatter TODO by id or ordinal.
#   plan_reopen_todo_cursor -- compatibility alias for plan_reopen_todo_yaml.
#   plan_reopen_todo_by_format -- reopen a TODO using the detected plan format.
#   plan_consolidate_todos -- collapse adjacent unchecked todos sharing prefix verb/noun (pure transform).
#   ralph_plan_split_preflight -- classify executable TODO blocks and optionally rewrite broad items.
#   ralph_plan_direct_verification_command -- return an allowlisted command for command-only verification TODOs.
#   ralph_workflow_stage_instructions_prompt_block -- delimited WORKFLOW_STAGE_INSTRUCTIONS prompt block.
#   ralph_workflow_operator_input_protocol_prompt_block -- delimited OPERATOR_INPUT protocol (no nonce).
#   ralph_workflow_operator_input_response_prompt_block -- delimited OPERATOR_INPUT_RESPONSE from a file.

# ralph_workflow_stage_instructions_prompt_block [text]
# Emit one delimited stage-instructions block for the run-plan prompt, or nothing
# when text is empty. With no args, reads RALPH_WORKFLOW_STAGE_INSTRUCTIONS.
# Does not write files; callers inject the block into the prompt only.
ralph_workflow_stage_instructions_prompt_block() {
  local text=""
  if [[ $# -gt 0 ]]; then
    text="$1"
  else
    text="${RALPH_WORKFLOW_STAGE_INSTRUCTIONS:-}"
  fi
  [[ -n "$text" ]] || return 0

  while [[ "$text" == *$'\n' || "$text" == *$'\r' ]]; do
    if [[ "$text" == *$'\n' ]]; then
      text="${text%$'\n'}"
    fi
    if [[ "$text" == *$'\r' ]]; then
      text="${text%$'\r'}"
    fi
  done
  [[ -n "$text" ]] || return 0

  printf '%s\n' "<!-- WORKFLOW_STAGE_INSTRUCTIONS: START -->"
  printf '%s\n' "$text"
  printf '%s\n' "<!-- WORKFLOW_STAGE_INSTRUCTIONS: END -->"
}

# ralph_workflow_operator_input_protocol_prompt_block
# Emit the bounded OPERATOR_INPUT protocol for workflow-owned ordinary stages.
# Prefer workflow_action_operator_input_protocol_block when that library is
# loaded; otherwise emit an identical local copy. Never includes nonce content.
ralph_workflow_operator_input_protocol_prompt_block() {
  if declare -F workflow_action_operator_input_protocol_block >/dev/null 2>&1; then
    workflow_action_operator_input_protocol_block
    return 0
  fi
  cat <<'EOF'
<!-- OPERATOR_INPUT: START -->
Continue autonomously through ordinary implementation choices supported by repository evidence.
When a missing product decision, unavailable credential configuration, external fact, or mutually exclusive requirement makes safe progress impossible:
1. Call `ralph workflow actions request --question <text> [--details <text>]`
2. Stop without completing the TODO and do not guess.
Credential questions must ask the operator to configure a named environment or native secret source and reply when ready; never request the secret value.
Standalone plans cannot create workflow requests; this protocol applies only under an active workflow-owned stage with supervisor-issued identity.
<!-- OPERATOR_INPUT: END -->
EOF
}

# ralph_workflow_operator_input_response_prompt_block [path]
# Emit a staged OPERATOR_INPUT_RESPONSE file into the prompt, or nothing when
# path is empty/missing. Does not mutate plans or include nonce content.
ralph_workflow_operator_input_response_prompt_block() {
  local path="${1:-${RALPH_WORKFLOW_OPERATOR_INPUT_RESPONSE_FILE:-}}"
  [[ -n "$path" && -f "$path" && ! -L "$path" && -s "$path" ]] || return 0
  cat -- "$path"
}

plan_normalize_path() {
  local path="$1"
  local workspace="$2"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return
  fi

  if [[ "$path" == ~* ]]; then
    printf '%s\n' "${path/#\~/$HOME}"
    return
  fi

  if [[ -n "$workspace" ]]; then
    printf '%s\n' "$workspace/$path"
  else
    printf '%s\n' "$path"
  fi
}

plan_log_basename() {
  local path="$1"
  local base
  base="$(basename "$path" | sed 's/\.[^.]*$//')"
  printf '%s\n' "$base" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

plan_format_is_yaml() {
  local format="${1:-}"
  [[ "$format" == "yaml" || "$format" == "cursor" ]]
}

plan_format_display() {
  local format="${1:-}"
  if plan_format_is_yaml "$format"; then
    printf 'yaml\n'
  else
    printf '%s\n' "${format:-default}"
  fi
}

plan_detect_format() {
  local plan_path="$1"
  local override="${RALPH_PLAN_FORMAT:-}"

  if [[ -n "$override" && "$override" != "default" && "$override" != "yaml" && "$override" != "cursor" ]]; then
    echo "Invalid RALPH_PLAN_FORMAT: $override (must be 'default' or 'yaml')" >&2
    return 1
  fi

  if [[ -n "$override" ]]; then
    if [[ "$override" == "cursor" ]]; then
      printf 'yaml\n'
    else
      printf '%s\n' "$override"
    fi
    return 0
  fi

  if head -1 "$plan_path" | grep -q "^---"; then
    grep -Eq '^[[:space:]]*todos:' "$plan_path" && printf 'yaml' || printf 'default'
  else
    printf 'default'
  fi
}

plan_todo_hash() {
  local text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$text" <<'PYTHON'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PYTHON
  elif command -v shasum &>/dev/null; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$text"
  fi
}

plan_yaml_frontmatter_op() {
  local plan_path="$1"
  local operation="$2"
  local target_content="${3:-}"
  local target_status="${4:-}"

  if command -v python3 &>/dev/null; then
    python3 - "$plan_path" "$operation" "$target_content" "$target_status" <<'PYTHON'
import re
import sys

plan_path = sys.argv[1]
operation = sys.argv[2]
target_content = sys.argv[3] if len(sys.argv) > 3 else ""
target_status = sys.argv[4] if len(sys.argv) > 4 else ""

with open(plan_path, encoding="utf-8") as fh:
    lines = fh.read().splitlines(True)

if not lines:
    raise SystemExit(1)

if lines[0].rstrip("\r\n") != "---":
    raise SystemExit(1)

closing_idx = None
for idx in range(1, len(lines)):
    if lines[idx].rstrip("\r\n") == "---":
        closing_idx = idx
        break
if closing_idx is None:
    raise SystemExit(1)

todo_items = []
in_todos = False
current = None
frontmatter_end = closing_idx


def line_indent(text: str) -> int:
    return len(text) - len(text.lstrip(" "))


def is_todo_item_line(line: str) -> bool:
    stripped = line.lstrip(" ")
    indent = len(line) - len(stripped)
    return indent <= 2 and stripped.startswith("- ")


def is_property_line(line: str) -> bool:
    return bool(re.match(r"^\s{4}[^:]+:\s*", line))


def status_is_done(status: str) -> bool:
    return status.strip().lower() in {"completed", "complete", "done"}


def consume_block_scalar(start_idx: int) -> tuple[str, int]:
    block_lines = []
    block_indent = None
    idx = start_idx + 1
    while idx < frontmatter_end:
        next_line = lines[idx]
        next_stripped = next_line.strip()
        next_indent = line_indent(next_line)
        if next_stripped != "" and (
            is_todo_item_line(next_line)
            or (is_property_line(next_line) and next_indent <= 4)
        ):
            break
        if next_stripped == "":
            block_lines.append("")
        else:
            if block_indent is None:
                block_indent = next_indent
            block_lines.append(next_line[block_indent:].rstrip("\r\n"))
        idx += 1
    return "\n".join(block_lines), idx


def resolve_target_item(target: str):
    if not target:
        raise SystemExit(1)

    id_matches = [item for item in todo_items if item.get("id", "") == target]
    if len(id_matches) > 1:
        raise SystemExit(1)
    if len(id_matches) == 1:
        return id_matches[0]

    if target.isdigit():
        ordinal = int(target)
        ordinal_matches = [item for item in todo_items if item.get("ordinal") == ordinal]
        if len(ordinal_matches) != 1:
            raise SystemExit(1)
        return ordinal_matches[0]

    raise SystemExit(1)


idx = 1
while idx < closing_idx:
    line = lines[idx]
    stripped = line.strip()
    if not in_todos:
        if stripped == "todos:":
            in_todos = True
        idx += 1
        continue

    if is_todo_item_line(line):
        if current is not None:
            todo_items.append(current)
        current = {
            "ordinal": len(todo_items) + 1,
            "start": idx,
            "content": "",
            "verification": "",
            "status": "",
            "id": "",
            "content_line": None,
            "verification_line": None,
            "status_line": None,
            "id_line": None,
        }
        m = re.match(r"^\s*-\s+([^:]+):\s*(.*)$", line)
        if m:
            key = m.group(1).strip()
            value = m.group(2).strip()
            line_idx = idx
            if value in {"|", "|-", "|+"}:
                value, idx = consume_block_scalar(idx)
            else:
                idx += 1
            if key == "content":
                current["content"] = value
                current["content_line"] = line_idx
            elif key == "verification":
                current["verification"] = value
                current["verification_line"] = line_idx
            elif key == "verify":
                current["verify"] = value
                current["verify_line"] = line_idx
            elif key == "status":
                current["status"] = value
                current["status_line"] = line_idx
            elif key == "id":
                current["id"] = value
                current["id_line"] = line_idx
            continue
        idx += 1
        continue

    if current is None:
        idx += 1
        continue

    if stripped == "":
        idx += 1
        continue

    m = re.match(r"^\s{4}([^:]+):\s*(.*)$", line)
    if m:
        key = m.group(1).strip()
        value = m.group(2).strip()
        line_idx = idx
        if value in {"|", "|-", "|+"}:
            value, idx = consume_block_scalar(idx)
        else:
            idx += 1
        if key == "content":
            current["content"] = value
            current["content_line"] = line_idx
        elif key == "verification":
            current["verification"] = value
            current["verification_line"] = line_idx
        elif key == "verify":
            current["verify"] = value
            current["verify_line"] = line_idx
        elif key == "status":
            current["status"] = value
            current["status_line"] = line_idx
        elif key == "id":
            current["id"] = value
            current["id_line"] = line_idx
        continue

    idx += 1

if current is not None:
    todo_items.append(current)

if operation == "get_next":
    for item in todo_items:
        if not status_is_done(str(item.get("status", ""))):
            print(f"{item.get('ordinal', '')}|{item.get('id', '')}|{item.get('content', '')}")
            raise SystemExit(0)
    raise SystemExit(1)

if operation == "count":
    done = sum(1 for item in todo_items if status_is_done(str(item.get("status", ""))))
    print(f"{done} {len(todo_items)}")
    raise SystemExit(0)

if operation == "get_verification":
    item = resolve_target_item(target_content)
    print(item.get("verification", ""))
    raise SystemExit(0)

if operation == "get_verify":
    item = resolve_target_item(target_content)
    print(item.get("verify", ""))
    raise SystemExit(0)

if operation == "set_status":
    item = resolve_target_item(target_content)
    status_line = item.get("status_line")
    if status_line is None:
        raise SystemExit(1)
    original_line = lines[status_line]
    stripped_line = original_line.rstrip("\r\n")
    newline = original_line[len(stripped_line) :]
    prefix_match = re.match(r"^(\s*status:\s*)", stripped_line)
    if prefix_match:
        prefix = prefix_match.group(1)
    else:
        indent_match = re.match(r"^(\s*)", stripped_line)
        prefix = f"{indent_match.group(1)}status: "
    lines[status_line] = f"{prefix}{target_status}{newline}"
    with open(plan_path, "w", encoding="utf-8", newline="") as fh:
        fh.write("".join(lines))
    raise SystemExit(0)

raise SystemExit(1)
PYTHON
  else
    return 1
  fi
}

plan_mark_todo_done_yaml() {
  local plan_path="$1"
  local todo_content="$2"
  plan_yaml_frontmatter_op "$plan_path" "set_status" "$todo_content" "completed"
}

plan_mark_todo_done_cursor() {
  plan_mark_todo_done_yaml "$@"
}

plan_yaml_update_todo_status() {
  local plan_path="$1"
  local todo_content="$2"
  local target_status="$3"
  plan_yaml_frontmatter_op "$plan_path" "set_status" "$todo_content" "$target_status"
}

plan_cursor_update_todo_status() {
  plan_yaml_update_todo_status "$@"
}

plan_cursor_frontmatter_op() {
  plan_yaml_frontmatter_op "$@"
}

# Open tasks must use "- [ ]" (space inside brackets). Plain "- []" is not matched so
# list lines that mention empty arrays / [] in prose are not mistaken for todos.
plan_open_todo_body() {
  local line="$1"
  printf '%s\n' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

plan_todo_has_continuation_lines() {
  local todo_text="$1"
  [[ "$todo_text" == *$'\n'* ]]
}

plan_pipeline_has_metadata() {
  local plan_path="$1"

  awk '
    BEGIN {
      in_frontmatter = 0
      has_pipeline = 0
      saw_closing = 0
    }
    NR == 1 && $0 == "---" {
      in_frontmatter = 1
      next
    }
    in_frontmatter && $0 == "---" {
      saw_closing = 1
      in_frontmatter = 0
      next
    }
    in_frontmatter && $0 ~ /^[[:space:]]*pipeline:[[:space:]]*/ {
      has_pipeline = 1
    }
    END {
      exit((saw_closing && has_pipeline) ? 0 : 1)
    }
  ' "$plan_path"
}

plan_pipeline_any_todo_has_routing() {
  local plan_path="$1"

  awk '
    BEGIN {
      in_frontmatter = 0
      in_todos = 0
      found = 0
      saw_closing = 0
    }
    NR == 1 && $0 == "---" {
      in_frontmatter = 1
      next
    }
    in_frontmatter && $0 == "---" {
      saw_closing = 1
      in_frontmatter = 0
      next
    }
    in_frontmatter && /^todos:[[:space:]]*$/ {
      in_todos = 1
      next
    }
    in_frontmatter && in_todos && /^[a-zA-Z]/ {
      in_todos = 0
    }
    in_frontmatter && in_todos && /^[[:space:]]+(runtime|agent|model|sessionStrategy|contextBudget|subagents|nativeSubagents):[[:space:]]/ {
      found = 1
    }
    END {
      exit((saw_closing && found) ? 0 : 1)
    }
  ' "$plan_path"
}

plan_pipeline_validate_plan() {
  local plan_path="$1"
  local format=""

  # Pipeline blocks always validate. Standard yaml-frontmatter plans (todos without
  # a pipeline) also validate so removed role / agent rules apply.
  if ! plan_pipeline_has_metadata "$plan_path"; then
    format="$(plan_detect_format "$plan_path" 2>/dev/null || true)"
    if ! plan_format_is_yaml "$format"; then
      return 0
    fi
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Error: pipeline-format plans require python3 for validation; classic markdown plans are the zero-dependency alternative." >&2
    return 1
  fi

  _plan_pipeline_metadata_json "$plan_path" "__validate__" "validate"
}

# plan_workflow_validate <path>
# Validate a reusable workflow source (.ralph-workspace/workflows/<name>.workflow.md).
plan_workflow_validate() {
  local plan_path="$1"

  if [ -z "$plan_path" ] || [ ! -f "$plan_path" ]; then
    echo "Error: plan_workflow_validate requires an existing workflow file path." >&2
    return 1
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Error: workflow files require python3 for validation." >&2
    return 1
  fi

  _plan_pipeline_metadata_json "$plan_path" "__workflow__" "workflow-validate"
}

# plan_workflow_instantiate <workflow_path> <task_text> <output_plan_path> [key=value...]
#
# Materializes a reusable workflow into an ordinary plan file by substituting
# the task text into every {{TASK}} occurrence in todo content, then applying
# selected fallback runtime/model only to unresolved executable stages.
# Optional key=value args:
#   fallback_runtime / fallback_model  -- invocation selection (skipped model = omit)
#   provided_plan_runtime / provided_plan_model -- supplied-plan header (consumer only)
#   metadata_out=<path> -- write captured run-entry metadata JSON (mode/defaults/planInput)
# The task is passed as an argv value and is never evaluated by the shell.
# The workflow source file is never mutated.
plan_workflow_instantiate() {
  local workflow_path="$1"
  local task_text="$2"
  local output_plan_path="$3"
  shift 3 || true
  local -a extra_kv=()
  local arg
  for arg in "$@"; do
    extra_kv+=("$arg")
  done

  if [ -z "$workflow_path" ] || [ ! -f "$workflow_path" ]; then
    echo "Error: plan_workflow_instantiate requires an existing workflow file path." >&2
    return 1
  fi

  if [ -z "$output_plan_path" ]; then
    echo "Error: $workflow_path: instantiating a workflow requires an output plan path." >&2
    return 1
  fi

  if [ -e "$output_plan_path" ]; then
    echo "Error: $workflow_path: refusing to overwrite existing output plan $output_plan_path" >&2
    return 1
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Error: workflow instantiation requires python3." >&2
    return 1
  fi

  _plan_pipeline_metadata_json "$workflow_path" "__workflow__" "workflow-instantiate" \
    "$task_text" "$output_plan_path" "${extra_kv[@]+"${extra_kv[@]}"}"
}

# plan_workflow_instantiate_provided <workflow_path> <task_text> <output_plan_path>
#   provided_plan_path=<imported-source> [key=value...]
#
# Plan-entry materialization. Identical to plan_workflow_instantiate except that
# the workflow must declare planInput, a required planInput is satisfied rather
# than refused, and {{INPUT_PLAN}} resolves to the imported immutable source
# path so the emitted plan carries no workflow-only token.
plan_workflow_instantiate_provided() {
  local workflow_path="$1"
  local task_text="$2"
  local output_plan_path="$3"
  shift 3 || true
  local -a extra_kv=()
  local arg
  for arg in "$@"; do
    extra_kv+=("$arg")
  done

  if [ -z "$workflow_path" ] || [ ! -f "$workflow_path" ]; then
    echo "Error: plan_workflow_instantiate_provided requires an existing workflow file path." >&2
    return 1
  fi

  if [ -z "$output_plan_path" ]; then
    echo "Error: $workflow_path: instantiating a workflow requires an output plan path." >&2
    return 1
  fi

  if [ -e "$output_plan_path" ]; then
    echo "Error: $workflow_path: refusing to overwrite existing output plan $output_plan_path" >&2
    return 1
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Error: workflow instantiation requires python3." >&2
    return 1
  fi

  _plan_pipeline_metadata_json "$workflow_path" "__workflow__" "workflow-instantiate-provided" \
    "$task_text" "$output_plan_path" "${extra_kv[@]+"${extra_kv[@]}"}"
}

_plan_pipeline_metadata_json() {
  local plan_path="$1"
  local target="$2"
  local mode="$3"
  shift 3
  local graph_authoring_contract
  graph_authoring_contract="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/schemas/graph-authoring-contract.json"
  local tooling_profiles_path
  tooling_profiles_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tooling-profiles.json"
  # Shared workflow instruction fragments ({{INCLUDE:<name>}}). Passed by env so
  # the positional argv contract for mode-specific extra args stays unchanged.
  local workflow_fragments_dir
  workflow_fragments_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workflows/_fragments"
  export RALPH_WORKFLOW_FRAGMENTS_DIR="$workflow_fragments_dir"

  if ! command -v python3 &>/dev/null; then
    echo "Error: pipeline-format metadata helpers require python3." >&2
    return 1
  fi

  python3 - "$plan_path" "$target" "$mode" "$graph_authoring_contract" "$tooling_profiles_path" "$@" <<'PYTHON'
import copy
import json
import os
import re
import sys
import tempfile

plan_path = sys.argv[1]
target = sys.argv[2]
mode = sys.argv[3]
graph_authoring_contract_path = sys.argv[4]
tooling_profiles_path = sys.argv[5]
# Mode-specific trailing arguments. workflow-instantiate uses:
#   argv[6] = task text (opaque data), argv[7] = output plan path,
#   argv[8...] = optional key=value (fallback_runtime, fallback_model,
#   provided_plan_runtime, provided_plan_model, metadata_out).
extra_args = sys.argv[6:]

try:
    with open(graph_authoring_contract_path, encoding="utf-8") as contract_handle:
        GRAPH_AUTHORING_CONTRACT = json.load(contract_handle)
except (OSError, ValueError) as exc:
    GRAPH_AUTHORING_CONTRACT = {}

try:
    with open(tooling_profiles_path, encoding="utf-8") as tooling_handle:
        TOOLING_PROFILES_DOC = json.load(tooling_handle)
except (OSError, ValueError):
    TOOLING_PROFILES_DOC = {}

TOOLING_PROFILE_NAMES = set(TOOLING_PROFILES_DOC.get("profiles", {}).keys())


def graph_contract_default(field: str, fallback):
    return GRAPH_AUTHORING_CONTRACT.get("defaults", {}).get(field, fallback)


def graph_contract_enum(field: str, fallback: set[str]) -> set[str]:
    values = (
        GRAPH_AUTHORING_CONTRACT.get("pipelineFields", {})
        .get(field, {})
        .get("enum", [])
    )
    return set(values) if values else fallback

ALLOWED_RUNTIMES = {"cursor", "claude", "codex", "opencode", "antigravity"}
RALPH_MODES = {"no", "native", "ralph", "hybrid"}
ALLOWED_SESSION_STRATEGIES = {"fresh", "resume", "reset", "compact"}
ALLOWED_CONTEXT_BUDGETS = {"full", "standard", "lean"}
# nativeSubagents is off|inherit. Standard default is inherit; graph/orchestration
# agent-stage default is off. inherit leaves runtime argv/config untouched; off
# is enforced by runtime adapters. Consensus voters are compile-forced to off.
# Supervisor node types (integrate/join/gate/checkpoint/router/approval) reject
# nativeSubagents and other agent/routing fields.
ALLOWED_NATIVE_SUBAGENTS = {"inherit", "off"}
# Runtimes with a proven nativeSubagents=off deny boundary. Keep in sync with
# graph_runtime_native_subagents_off_deny in
# bundle/.ralph/bash-lib/graph/graph-runtime-capabilities.sh; the drift is
# asserted by tests/bats/graph/graph-native-subagent.bats.
NATIVE_SUBAGENTS_OFF_SUPPORTED_RUNTIMES = {"claude", "codex"}


def staged_native_subagents_default(runtime: str) -> str:
    """Graph/orchestration agent stages default to off only where off can
    actually be enforced. On a runtime with no proven deny boundary Ralph must
    not pick a value that would refuse to invoke: the author never asked for
    off, so the ambient (inherit) behaviour stands. An explicitly authored off
    on such a runtime still fails loudly at preflight."""
    if as_text(runtime) in NATIVE_SUBAGENTS_OFF_SUPPORTED_RUNTIMES:
        return "off"
    return "inherit"
SUPERVISOR_STAGE_TYPES = {"integrate", "join", "gate", "checkpoint", "router", "approval"}
# Public supervisor type: approval. Authored fields only; never agent/routing/
# tooling/plan/workspace/Git, and never legacy humanAck/checkpoint vocabulary.
APPROVAL_STAGE_ALLOWED_KEYS = frozenset(
    {"id", "type", "question", "changesTarget", "dependsOn", "requires", "ordinal"}
)
APPROVAL_STAGE_FORBIDDEN_FIELDS = frozenset(
    {
        "runtime",
        "model",
        "agent",
        "agentSource",
        "role",
        "instructions",
        "planFile",
        "planFrom",
        "planner",
        "workspaceMode",
        "writeScopes",
        "parallelMutation",
        "acknowledgeSharedMutationRisk",
        "agentGitAccess",
        "setupProfile",
        "toolingProfile",
        "contextBudget",
        "sessionStrategy",
        "nativeSubagents",
        "subagents",
        "delegation",
        "router",
        "voters",
        "policy",
        "quorum",
        "minRuntimes",
        "grader",
        "rubric",
        "humanAck",
        "loopBackTo",
        "loopCheck",
        "maxIterations",
        "onExhausted",
        "profile",
        "overlapOwner",
        "ownershipRole",
        "produces",
        "content",
        "verification",
        "sessionResume",
        "onVoterError",
        "verdictSchema",
    }
)
BLOCK_INDICATORS = {"|", "|-", "|+"}
STAGE_ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
# Delegated-run role ids (delegation.delegatedRuns.roles) keep the stage-id grammar.
ROLE_ID_RE = STAGE_ID_RE
# Stale authored role: fields are refused; stage guidance is inline instructions.
REMOVED_ROLE_GUIDANCE = (
    "was removed. Use inline workflow instructions (instructions: text)"
)
# Authored planner config: plan-file only; legacy role/runtime/model caps removed.
PLANNER_OUTPUT_SCHEMA = "bundle/.ralph/schemas/planner-output.schema.json"
PLANNER_DEFAULT_MAX_TODOS = 100
PLANNER_HARD_MAX_TODOS = 200
REMOVED_PLANNER_KEYS = frozenset(
    {"allowedRoles", "allowedRuntimes", "allowedModels", "maxStages", "defaultRole"}
)
REMOVED_PLANNER_GUIDANCE = (
    "was removed. Use planner: {outputMode: plan-file, maxTodos: <n>} "
    "for a generated Ralph plan"
)
# Inline stage/voter/repair instructions are text only. Path/include keys are
# refused so authors cannot smuggle external role files back in.
INSTRUCTIONS_PATH_INCLUDE_KEYS = {
    "instructionsPath",
    "instructionsInclude",
    "instructionPath",
    "instructionInclude",
}


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def warn(message: str) -> None:
    print(f"Warning: {message}", file=sys.stderr)


def read_lines(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


def is_blank_or_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped == "" or stripped.startswith("#")


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def next_significant(lines: list[str], idx: int) -> int:
    while idx < len(lines) and is_blank_or_comment(lines[idx]):
        idx += 1
    return idx


def split_key_value(text: str) -> tuple[str, str]:
    if ":" not in text:
        return text.strip(), ""
    key, raw = text.split(":", 1)
    return key.strip(), raw.lstrip()


def strict_keys_enabled(execution: str) -> bool:
    import os

    value = os.environ.get("RALPH_PLAN_STRICT_KEYS", "")
    if value:
        return value.lower() not in {"0", "false", "no", "off"}
    return execution in {"orchestration", "graph"}


def parse_scalar_text(text: str) -> str:
    value = text.strip()
    if not value:
        return ""
    if len(value) >= 2 and ((value[0] == value[-1] == "'") or (value[0] == value[-1] == '"')):
        return value[1:-1]
    return value


def parse_bool_text(text: str) -> bool:
    value = text.strip().lower()
    if value == "true":
        return True
    if value == "false":
        return False
    fail(f"invalid boolean value {text!r}")


def parse_int_text(text: str) -> int:
    value = text.strip()
    if not re.fullmatch(r"[0-9]+", value):
        fail(f"invalid integer value {text!r}")
    return int(value)


def parse_block_scalar(lines: list[str], start_idx: int, key_indent: int) -> tuple[str, int]:
    block_lines: list[str] = []
    block_indent = None
    idx = start_idx + 1
    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()
        current_indent = indent_of(line)
        if stripped != "" and current_indent <= key_indent:
            break
        if stripped == "":
            block_lines.append("")
        else:
            if block_indent is None:
                block_indent = current_indent
            block_lines.append(line[block_indent:].rstrip("\r\n"))
        idx += 1
    return "\n".join(block_lines), idx


def parse_artifact_item(lines: list[str], start_idx: int, item_indent: int) -> tuple[dict, int]:
    line = lines[start_idx]
    payload = line[item_indent:].lstrip()
    if not payload.startswith("-"):
        fail("artifact list item missing '-' prefix")
    item = {"required": True}
    consumed_idx = start_idx + 1

    fragment = payload[1:].lstrip()
    if fragment:
        if ":" not in fragment:
            item["__shorthand"] = fragment
            return item, consumed_idx
        key, raw = split_key_value(fragment)
        if key not in {"path", "required", "schema"}:
            fail(f"unsupported artifact field {key!r}")
        if key == "path":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact path must not be empty")
            item["path"] = value
        elif key == "schema":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact schema must not be empty")
            item["schema"] = value
        else:
            item["required"] = parse_bool_text(raw)

    idx = consumed_idx
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= item_indent:
            break
        key, raw = split_key_value(line.strip())
        if key not in {"path", "required", "schema"}:
            fail(f"unsupported artifact field {key!r}")
        if key == "path":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact path must not be empty")
            item["path"] = value
        elif key == "schema":
            value = parse_scalar_text(raw)
            if not value:
                fail("artifact schema must not be empty")
            item["schema"] = value
        else:
            item["required"] = parse_bool_text(raw)
        idx += 1

    if "path" not in item:
        fail("artifact entry missing path")
    return item, idx


def parse_artifact_list(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list, int]:
    items = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        if not line[current_indent:].lstrip().startswith("-"):
            break
        item_indent = current_indent
        item, idx = parse_artifact_item(lines, idx, item_indent)
        items.append(item)
    return items, idx


def _scan_bracket_content(text: str, field_name: str) -> str:
    """Return the content between the outermost balanced brackets in text.

    Fails with a named error if the brackets are missing or unbalanced.
    This is the same depth-first scanner used by parse_parallel_stages_inline,
    factored out so parse_string_list can reuse it.
    """
    depth = 0
    start = None
    for i, ch in enumerate(text):
        if ch == "[":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "]":
            if depth == 0:
                fail(f"{field_name}: unbalanced brackets")
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
    if depth != 0 or start is None:
        fail(f"{field_name}: unbalanced brackets")
    return text[start + 1 :]


def parse_string_list(text: str, lines: list[str], start_idx: int, parent_indent: int, field_name: str) -> tuple[list[str], int]:
    """Parse a list of strings in either inline bracketed form or block dash form.

    Inline form: [a, b, c]
    Block form:
      - a
      - b
      - c

    Empty inline: [] or an empty block both yield an empty list.
    Reuses the bracket scanner already present in parse_parallel_stages_inline.
    """
    value = text.strip()
    if value == "[]":
        return [], start_idx
    if value.startswith("["):
        inner = _scan_bracket_content(value, field_name).strip()
        if not inner:
            return [], start_idx
        return [parse_scalar_text(part) for part in inner.split(",") if part.strip()], start_idx

    items = []
    idx = next_significant(lines, start_idx)
    first_item_indent = None
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if first_item_indent is None:
            if current_indent <= parent_indent:
                break
            if not line[current_indent:].lstrip().startswith("-"):
                break
            first_item_indent = current_indent
        else:
            if current_indent < first_item_indent:
                break
            if current_indent == first_item_indent and not line[current_indent:].lstrip().startswith("-"):
                break
        payload = line[first_item_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].strip()
        if fragment:
            # YAML-quoted scalars (e.g. writeScopes: ["**"]) must shed quotes.
            items.append(parse_scalar_text(fragment))
        idx += 1
    return items, idx


def parse_dep_list(text: str, lines: list[str], start_idx: int, parent_indent: int, field_name: str) -> tuple[list, int]:
    """Parse a dependsOn list where each entry is either a plain string or a dict with 'id' and optional 'condition'.

    Block dict form (conditional edge):
      - id: some-stage
        condition: passed

    Block plain form (unconditional edge):
      - some-stage

    Inline form (strings only): [a, b, c]
    """
    value = text.strip()
    if value == "[]":
        return [], start_idx
    if value.startswith("["):
        # Inline form: only simple strings are supported.
        inner = _scan_bracket_content(value, field_name).strip()
        if not inner:
            return [], start_idx
        return [part.strip() for part in inner.split(",") if part.strip()], start_idx

    items: list = []
    idx = next_significant(lines, start_idx)
    first_item_indent = None
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if first_item_indent is None:
            if current_indent <= parent_indent:
                break
            if not line[current_indent:].lstrip().startswith("-"):
                break
            first_item_indent = current_indent
        else:
            if current_indent < first_item_indent:
                break
            if current_indent == first_item_indent and not line[current_indent:].lstrip().startswith("-"):
                break
        payload = line[first_item_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].strip()
        idx += 1
        if not fragment:
            continue
        # Check if this item starts with "id:" making it a dict-form entry.
        kv_key, kv_raw = split_key_value(fragment)
        if kv_key == "id":
            dep_id = parse_scalar_text(kv_raw)
            dep_entry: dict = {"id": dep_id}
            # Consume sub-keys (condition, etc.) at higher indentation.
            while idx < len(lines):
                sub_line = lines[idx]
                if is_blank_or_comment(sub_line):
                    idx += 1
                    continue
                sub_indent = indent_of(sub_line)
                if sub_indent <= first_item_indent:
                    break
                sub_key, sub_raw = split_key_value(sub_line.strip())
                if sub_key == "condition":
                    dep_entry["condition"] = parse_scalar_text(sub_raw)
                # Unknown sub-keys are silently skipped for forward compatibility.
                idx += 1
            items.append(dep_entry)
        else:
            # Plain string entry.
            items.append(fragment)
    return items, idx


def parse_loop_check(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    obj = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key in ("path", "schema"):
            value = parse_scalar_text(raw)
            if value:
                obj[key] = value
        idx += 1
    return obj, idx


def parse_planner_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse authored planner: {outputMode, maxTodos} only."""
    planner: dict = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key in REMOVED_PLANNER_KEYS:
            fail(f"planner.{key}: {REMOVED_PLANNER_GUIDANCE}")
        if key not in {"outputMode", "maxTodos"}:
            fail(
                f"planner: unknown field {key!r}; "
                "only outputMode and maxTodos are permitted"
            )
        stripped = raw.strip()
        if stripped in {"[]", "{}"}:
            fail(f"planner.{key}: must be a scalar")
        if stripped == "":
            peek = next_significant(lines, idx + 1)
            if peek < len(lines) and indent_of(lines[peek]) > current_indent:
                fail(f"planner.{key}: must be a scalar")
            fail(f"planner.{key}: must be a scalar")
        if stripped in BLOCK_INDICATORS:
            fail(f"planner.{key}: must be a scalar")
        value = parse_scalar_text(raw)
        if not value:
            fail(f"planner.{key}: must be a scalar")
        if key == "maxTodos":
            planner[key] = parse_int_text(value)
        else:
            planner[key] = value
        idx += 1
    return planner, idx


def parse_router_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    router = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key in ("allowedTargets", "terminalOutcomes"):
            value, next_idx = parse_string_list(raw, lines, idx + 1, current_indent, f"router {key}")
            router[key] = value
            idx = next_idx
            continue
        if key in ("defaultTarget", "onInvalid"):
            value = parse_scalar_text(raw)
            if value:
                router[key] = value
        idx += 1
    return router, idx


def parse_tooling_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse pipeline.tooling: a run-level default tool-exposure profile plus
    optional per-stage overrides. This is the tooling-profile alternative to
    pipeline.ralphMode; validate_pipeline_plan rejects declaring both."""
    tooling = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key == "defaultProfile":
            value = parse_scalar_text(raw)
            if value:
                tooling[key] = value
            idx += 1
            continue
        if key == "overrides":
            if raw.strip() not in {"", "{}"}:
                fail("pipeline.tooling.overrides: must use mapping syntax")
            overrides = {}
            over_idx = next_significant(lines, idx + 1)
            while over_idx < len(lines):
                over_line = lines[over_idx]
                if is_blank_or_comment(over_line):
                    over_idx += 1
                    continue
                over_indent = indent_of(over_line)
                if over_indent <= current_indent:
                    break
                over_key, over_raw = split_key_value(over_line.strip())
                over_value = parse_scalar_text(over_raw)
                if over_key and over_value:
                    overrides[over_key] = over_value
                over_idx += 1
            tooling[key] = overrides
            idx = over_idx
            continue
        fail(f"pipeline.tooling: unknown field {key!r}")
    return tooling, idx


def parse_delegation_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse the deliberately small delegated-runs delegation contract.

    This parser does not use a general YAML mapping on purpose: graph plans have
    strict keys, and accepting arbitrary child-policy fields would make the
    frozen policy impossible to audit.
    """
    delegation = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key == "native":
            fail(
                "delegation.native: was removed. Use nativeSubagents: off|inherit. "
                "Use current workflow fields (see DELEGATION.md)"
            )
        if key in {"crossRuntime", "maxChildren"}:
            fail(
                f"delegation.{key}: was removed. Use delegation.delegatedRuns. "
                f"Use current workflow fields (see DELEGATION.md)"
            )
        if key != "delegatedRuns":
            fail(f"delegation: unknown field {key!r}")
        if raw.strip() not in {"", "{}"}:
            fail(f"delegation.{key}: must use mapping syntax")
        child = {}
        idx = next_significant(lines, idx + 1)
        while idx < len(lines):
            child_line = lines[idx]
            if is_blank_or_comment(child_line):
                idx += 1
                continue
            child_indent = indent_of(child_line)
            if child_indent <= current_indent:
                break
            child_key, child_raw = split_key_value(child_line.strip())
            if child_key in {"runtimes", "roles"}:
                child[child_key], idx = parse_string_list(child_raw, lines, idx + 1, child_indent, f"delegation.{key}.{child_key}")
                continue
            if child_key in {"maxRuns", "maxParallel"}:
                child[child_key] = parse_int_text(parse_scalar_text(child_raw) or "0")
            elif child_key == "mode":
                child[child_key] = parse_scalar_text(child_raw)
            else:
                fail(f"delegation.{key}: unknown field {child_key!r}")
            idx += 1
        delegation[key] = child
    return delegation, idx


def parse_parallel_wave(text: str) -> list[str]:
    value = text.strip()
    if not value:
        return []
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [part.strip() for part in inner.split(",") if part.strip()]
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_parallel_stages_inline(text: str) -> list[list[str]]:
    value = text.strip()
    if value == "[]":
        return []
    if not (value.startswith("[") and value.endswith("]")):
        fail("pipeline.parallelStages: must use array-of-arrays syntax")
    waves = []
    depth = 0
    current = []
    for ch in value[1:-1]:
        if ch == "[":
            depth += 1
            if depth == 1:
                current = []
            else:
                current.append(ch)
        elif ch == "]":
            if depth == 0:
                fail("pipeline.parallelStages: has unbalanced brackets")
            depth -= 1
            if depth == 0:
                waves.append(parse_parallel_wave("".join(current)))
            else:
                current.append(ch)
        elif depth > 0:
            current.append(ch)
        else:
            if ch not in " \t,":
                fail("pipeline.parallelStages: must contain only nested stage-id arrays")
    if depth != 0:
        fail("pipeline.parallelStages: has unbalanced brackets")
    return waves


def parse_parallel_stages_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list[list[str]], int]:
    waves = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        payload = line[current_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].strip()
        if fragment:
            waves.append(parse_parallel_wave(fragment))
            idx += 1
        else:
            nested_idx = next_significant(lines, idx + 1)
            if nested_idx >= len(lines) or indent_of(lines[nested_idx]) <= current_indent:
                waves.append([])
                idx += 1
            else:
                waves.append(parse_parallel_wave(lines[nested_idx].strip()))
                idx = nested_idx + 1
    return waves, idx


def parse_scalar_field(lines: list[str], idx: int, key_indent: int, raw: str, key: str) -> tuple[int, object]:
    if raw in BLOCK_INDICATORS:
        value, next_idx = parse_block_scalar(lines, idx, key_indent)
        return next_idx, value
    if key == "maxIterations":
        value = parse_scalar_text(raw)
        if not value:
            fail("maxIterations must not be empty")
        return idx + 1, parse_int_text(value)
    if key in {"quorum", "minRuntimes"}:
        value = parse_scalar_text(raw)
        if not value:
            fail(f"{key} must not be empty")
        return idx + 1, parse_int_text(value)
    if key in {"required", "acknowledgeSharedMutationRisk"}:
        return idx + 1, parse_bool_text(raw)
    if key == "grader":
        return idx + 1, parse_bool_text(raw)
    return idx + 1, parse_scalar_text(raw)


def parse_instructions_field(
    lines: list[str], idx: int, key_indent: int, raw: str, prefix: str = "instructions"
) -> tuple[int, str]:
    """Parse non-empty scalar or block-scalar instructions text exactly.

    Lists, maps, empty values, and path/include indirection are rejected at
    parse time so workflow stage guidance stays inline text only.
    """
    stripped = raw.strip()
    if stripped in {"[]", "{}"}:
        fail(
            f"{prefix}: must be non-empty text (scalar or block scalar), "
            "not a list or map"
        )
    if stripped == "":
        peek = next_significant(lines, idx + 1)
        if peek < len(lines) and indent_of(lines[peek]) > key_indent:
            fail(
                f"{prefix}: must be non-empty text (scalar or block scalar), "
                "not a list or map"
            )
        fail(f"{prefix}: must be non-empty text")
    if stripped in BLOCK_INDICATORS:
        value, next_idx = parse_block_scalar(lines, idx, key_indent)
        if not str(value).strip():
            fail(f"{prefix}: must be non-empty text")
        return next_idx, value
    value = parse_scalar_text(raw)
    if not value:
        fail(f"{prefix}: must be non-empty text")
    return idx + 1, value


def reject_instructions_path_include_key(key: str, prefix: str) -> None:
    if key in INSTRUCTIONS_PATH_INCLUDE_KEYS:
        fail(
            f"{prefix} {key}: path/include keys are not allowed; "
            "put non-empty text on instructions: (scalar or block scalar)"
        )


def reject_removed_role_key(key: str, prefix: str) -> None:
    """Refuse authored role: at parse time so it is never silently ignored."""
    if key == "role":
        fail(f"{prefix} role: {REMOVED_ROLE_GUIDANCE}")


def reject_stale_role(obj: dict, prefix: str) -> None:
    """Refuse a stale role field on already-parsed stage/TODO/voter/repair objects."""
    if "role" in obj:
        fail(f"{prefix} role: {REMOVED_ROLE_GUIDANCE}")


def validate_instructions_value(value, prefix: str) -> None:
    if isinstance(value, (list, dict)):
        fail(
            f"{prefix} instructions: must be non-empty text (scalar or block scalar), "
            "not a list or map"
        )
    text = as_text(value)
    if not text.strip():
        fail(f"{prefix} instructions: must be non-empty text")


def validate_instructions_allowed(obj: dict, prefix: str, allowed: bool, owner_label: str) -> None:
    if "instructions" not in obj:
        return
    if not allowed:
        fail(
            f"{prefix} instructions: {owner_label} do not take instructions; "
            "instructions are allowed on agent stages, repair diagnose/lanes, "
            "and consensus voters only"
        )
    validate_instructions_value(obj.get("instructions"), prefix)


def parse_list_item(lines: list[str], start_idx: int, item_indent: int, kind: str, execution: str) -> tuple[dict, int]:
    line = lines[start_idx]
    payload = line[item_indent:].lstrip()
    if not payload.startswith("-"):
        fail(f"{kind} item missing '-' prefix")
    fragment = payload[1:].lstrip()
    item = {}
    idx = start_idx + 1

    def consume_field(key: str, raw: str, line_idx: int, line_indent: int) -> tuple[int, object]:
        reject_instructions_path_include_key(key, f"{kind} item")
        reject_removed_role_key(key, f"{kind} item")
        if key == "instructions":
            return parse_instructions_field(
                lines, line_idx, line_indent, raw, f"{kind} instructions"
            )
        if key in {"content", "verification", "status", "id", "stage", "runtime", "agent", "agentSource", "model", "sessionStrategy", "contextBudget", "subagents", "nativeSubagents", "type", "policy", "onVoterError", "verdictSchema", "quorum", "minRuntimes", "loopBackTo", "onExhausted", "planFile", "planFrom", "grader", "rubric", "workspaceMode", "setupProfile", "agentGitAccess", "parallelMutation", "acknowledgeSharedMutationRisk", "profile", "overlapOwner", "ownershipRole", "toolingProfile", "question", "changesTarget", "addressesFinding"}:
            return parse_scalar_field(lines, line_idx, line_indent, raw, key)
        if key == "maxIterations":
            return parse_scalar_field(lines, line_idx, line_indent, raw, key)
        if key == "requires" or key == "produces":
            if raw.strip() not in {"", "[]"}:
                item[f"__{key}_shorthand"] = raw.strip()
                return line_idx + 1, []
            value, next_idx = parse_artifact_list(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "dependsOn":
            value, next_idx = parse_dep_list(raw, lines, line_idx + 1, line_indent, f"{kind} dependsOn")
            return next_idx, value
        if key == "writeScopes":
            value, next_idx = parse_string_list(raw, lines, line_idx + 1, line_indent, f"{kind} writeScopes")
            return next_idx, value
        if key == "voters":
            if raw.strip() not in {"", "[]"}:
                fail(f"{kind} voters must use list syntax")
            value, next_idx = parse_items(lines, line_idx + 1, line_indent, "voter", execution)
            return next_idx, value
        if key == "loopCheck":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} loopCheck must use mapping syntax")
            value, next_idx = parse_loop_check(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "planner":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} planner must use mapping syntax")
            value, next_idx = parse_planner_block(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "router":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} router must use mapping syntax")
            value, next_idx = parse_router_block(lines, line_idx + 1, line_indent)
            return next_idx, value
        if key == "delegation":
            if raw.strip() not in {"", "{}"}:
                fail(f"{kind} delegation must use mapping syntax")
            value, next_idx = parse_delegation_block(lines, line_idx + 1, line_indent)
            return next_idx, value
        if strict_keys_enabled(execution):
            owner = item.get("id") or f"{kind} item"
            fail(f"unknown {kind} field {key!r} on {owner}")
        return line_idx + 1, None

    if fragment:
        key, raw = split_key_value(fragment)
        next_idx, value = consume_field(key, raw, start_idx, item_indent)
        if value is not None:
            item[key] = value
        idx = next_idx

    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= item_indent:
            break
        key, raw = split_key_value(line.strip())
        next_idx, value = consume_field(key, raw, idx, current_indent)
        if value is not None:
            item[key] = value
        idx = next_idx

    return item, idx


def parse_items(lines: list[str], start_idx: int, parent_indent: int, kind: str, execution: str) -> tuple[list[dict], int]:
    items = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        payload = line[current_indent:].lstrip()
        if not payload.startswith("-"):
            break
        item, idx = parse_list_item(lines, idx, current_indent, kind, execution)
        items.append(item)
    return items, idx


# Hard ceiling on pipeline.repairRounds.rounds. This is a fixed constant, not
# an authorable field: version 1 defaults to two rounds and operators may
# raise it for a given plan, but never past this bound. Keep the bounded
# repair-epoch macro genuinely bounded rather than trusting authoring input.
REPAIR_ROUNDS_HARD_MAX = 5

# Hard ceiling on pipeline.maxReworkIterations. Same rationale as
# REPAIR_ROUNDS_HARD_MAX above: this is a fixed constant, not an authorable
# field, bounding how many rework iterations a graph plan may declare.
REWORK_ITERATIONS_HARD_MAX = 5

# The only evaluator-verdict schema graph rework trusts. The scheduler helper
# that drives the loopBackTo rework macro parses verdicts against this exact
# bundled schema, so a stage that wants scheduler-driven rework must declare
# it verbatim; loose schema matching would let a plan silently bypass the
# verdict contract the scheduler assumes.
GRAPH_REWORK_EVALUATOR_SCHEMA = "bundle/.ralph/schemas/evaluator-verdict.schema.json"


def parse_repair_phase_block(lines: list[str], start_idx: int, parent_indent: int, phase_name: str) -> tuple[dict, int]:
    """Parse a singular repairRounds phase mapping (integrate/gate/diagnose/
    reintegrate). Deliberately small field set mirroring the ordinary stage
    fields that matter for a model-free or ordinary-agent graph node."""
    obj: dict = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        reject_instructions_path_include_key(key, f"repairRounds.{phase_name}")
        reject_removed_role_key(key, f"repairRounds.{phase_name}")
        if key == "instructions":
            idx, value = parse_instructions_field(
                lines, idx, current_indent, raw, f"repairRounds.{phase_name}.instructions"
            )
            obj[key] = value
            continue
        if key in {"runtime", "agent", "agentSource", "model", "content", "verification", "profile", "workspaceMode", "agentGitAccess", "setupProfile", "nativeSubagents", "subagents"}:
            idx, value = parse_scalar_field(lines, idx, current_indent, raw, key)
            if value not in (None, ""):
                obj[key] = value
            continue
        if key in {"requires", "produces"}:
            if raw.strip() not in {"", "[]"}:
                fail(f"repairRounds.{phase_name}.{key} must use list syntax")
            obj[key], idx = parse_artifact_list(lines, idx + 1, current_indent)
            continue
        fail(f"repairRounds.{phase_name}: unknown field {key!r}")
    return obj, idx


def parse_repair_rounds_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse the pipeline.repairRounds compile-time authoring macro (v2-repair-epochs).

    Expands (elsewhere, at graph-compile time) into a bounded acyclic sequence:
    integrate, gate, then rounds many repeats of diagnose/repair-lanes/
    reintegrate/regate. This parser only captures the authored templates; the
    expansion itself lives in expand_repair_rounds_nodes.
    """
    rr: dict = {"lanes": []}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key == "id":
            value = parse_scalar_text(raw)
            if value:
                rr["id"] = value
            idx += 1
            continue
        if key == "rounds":
            value = parse_scalar_text(raw)
            rr["rounds"] = parse_int_text(value) if value else 2
            idx += 1
            continue
        if key == "dependsOn":
            rr["dependsOn"], idx = parse_dep_list(raw, lines, idx + 1, current_indent, "repairRounds dependsOn")
            continue
        if key in {"integrate", "gate", "diagnose", "reintegrate"}:
            if raw.strip() not in {"", "{}"}:
                fail(f"repairRounds.{key} must use mapping syntax")
            rr[key], idx = parse_repair_phase_block(lines, idx + 1, current_indent, key)
            continue
        if key == "lanes":
            if raw.strip() not in {"", "[]"}:
                fail("repairRounds.lanes must use list syntax")
            rr["lanes"], idx = parse_items(lines, idx + 1, current_indent, "repair-lane", "graph")
            continue
        fail(f"unknown repairRounds field {key!r}")
    rr.setdefault("rounds", 2)
    return rr, idx


def parse_verification_step(lines: list[str], start_idx: int, item_indent: int) -> tuple[dict, int]:
    """Parse one operator-authored, model-free verification-profile step."""
    line = lines[start_idx]
    payload = line[item_indent:].lstrip()
    if not payload.startswith("-"):
        fail("verificationProfiles step missing '-' prefix")
    fragment = payload[1:].lstrip()
    step: dict = {}
    idx = start_idx + 1

    def consume(key: str, raw: str, line_idx: int, line_indent: int) -> int:
        if key in {"name", "command", "resourceClass"}:
            next_idx, value = parse_scalar_field(lines, line_idx, line_indent, raw, key)
            step[key] = value
            return next_idx
        if key == "timeout":
            value = parse_scalar_text(raw)
            step[key] = parse_int_text(value) if value else 300
            return line_idx + 1
        if key == "continueOnFailure":
            step[key] = parse_bool_text(raw)
            return line_idx + 1
        if key == "requiredArtifacts":
            step[key], next_idx = parse_string_list(
                raw, lines, line_idx + 1, line_indent,
                "verificationProfiles step requiredArtifacts",
            )
            return next_idx
        fail(f"verificationProfiles step: unknown field {key!r}")

    if fragment:
        key, raw = split_key_value(fragment)
        idx = consume(key, raw, start_idx, item_indent)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= item_indent:
            break
        key, raw = split_key_value(line.strip())
        idx = consume(key, raw, idx, current_indent)
    return step, idx


def parse_verification_steps(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list[dict], int]:
    steps: list[dict] = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        if not line[current_indent:].lstrip().startswith("-"):
            break
        step, idx = parse_verification_step(lines, idx, current_indent)
        steps.append(step)
    return steps, idx


def parse_verification_profiles(lines: list[str], start_idx: int, parent_indent: int) -> tuple[list[dict], int]:
    """Parse pipeline.verificationProfiles without requiring a YAML dependency."""
    profiles: list[dict] = []
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        item_indent = indent_of(line)
        if item_indent <= parent_indent:
            break
        payload = line[item_indent:].lstrip()
        if not payload.startswith("-"):
            break
        fragment = payload[1:].lstrip()
        profile: dict = {"steps": []}
        # The inline fragment after "-" may be any profile field, not just name:
        # a materialized plan round-trips these through a dict whose key order is
        # not the authored order, so demanding name-first made every instantiated
        # workflow that declares a profile fail to compile.
        inline_steps = False
        if fragment:
            key, raw = split_key_value(fragment)
            if key == "name":
                profile["name"] = parse_scalar_text(raw)
            elif key == "steps":
                if raw.strip() not in {"", "[]"}:
                    fail("verificationProfiles steps must use list syntax")
                inline_steps = True
            else:
                fail(f"verificationProfiles entry: unknown field {key!r}")
        idx += 1
        if inline_steps:
            profile["steps"], idx = parse_verification_steps(lines, idx, item_indent + 2)
        while idx < len(lines):
            nested = lines[idx]
            if is_blank_or_comment(nested):
                idx += 1
                continue
            current_indent = indent_of(nested)
            if current_indent <= item_indent:
                break
            key, raw = split_key_value(nested.strip())
            if key == "name":
                profile["name"] = parse_scalar_text(raw)
                idx += 1
                continue
            if key == "steps":
                if raw.strip() not in {"", "[]"}:
                    fail("verificationProfiles steps must use list syntax")
                profile["steps"], idx = parse_verification_steps(lines, idx + 1, current_indent)
                continue
            fail(f"verificationProfiles entry: unknown field {key!r}")
        profiles.append(profile)
    return profiles, idx


def parse_pipeline(lines: list[str], start_idx: int, parent_indent: int, execution: str) -> tuple[dict, int]:
    pipeline = {"stages": [], "parallelStages": []}
    if execution == "graph":
        if not GRAPH_AUTHORING_CONTRACT:
            fail(f"missing or invalid graph authoring contract: {graph_authoring_contract_path}")
        pipeline.update({
            "maxParallel": graph_contract_default("maxParallel", 3),
            "edgeDerivation": graph_contract_default("edgeDerivation", "both"),
            "failurePolicy": graph_contract_default("failurePolicy", "drain"),
            "publishMode": graph_contract_default("publishMode", "manual"),
            "strictEdges": bool(graph_contract_default("strictEdges", False)),
        })
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key == "stages":
            if raw.strip() not in {"", "[]"}:
                fail("pipeline.stages must use list syntax")
            pipeline["stages"], idx = parse_items(lines, idx + 1, current_indent, "stage", execution)
            continue
        if key == "parallelStages":
            if raw.strip():
                pipeline["parallelStages"] = parse_parallel_stages_inline(raw)
                idx += 1
            else:
                pipeline["parallelStages"], idx = parse_parallel_stages_block(lines, idx + 1, current_indent)
            continue
        if execution == "graph" and key == "maxParallel":
            value = parse_scalar_text(raw)
            parsed = parse_int_text(value or str(graph_contract_default("maxParallel", 3)))
            minimum = int(
                GRAPH_AUTHORING_CONTRACT.get("pipelineFields", {})
                .get("maxParallel", {})
                .get("minimum", 1)
            )
            if parsed < minimum:
                fail(f"maxParallel must be an integer greater than or equal to {minimum}")
            pipeline["maxParallel"] = parsed
            idx += 1
            continue
        if execution == "graph" and key == "edgeDerivation":
            value = parse_scalar_text(raw) or str(graph_contract_default("edgeDerivation", "both"))
            if value not in graph_contract_enum("edgeDerivation", {"declared", "artifacts", "both"}):
                fail("invalid edgeDerivation value")
            pipeline["edgeDerivation"] = value
            idx += 1
            continue
        if execution == "graph" and key == "failurePolicy":
            value = parse_scalar_text(raw) or str(graph_contract_default("failurePolicy", "drain"))
            if value not in graph_contract_enum("failurePolicy", {"drain", "cancel"}):
                fail("invalid failurePolicy value")
            pipeline["failurePolicy"] = value
            idx += 1
            continue
        if execution == "graph" and key == "publishMode":
            value = parse_scalar_text(raw) or str(graph_contract_default("publishMode", "manual"))
            if value not in graph_contract_enum("publishMode", {"manual", "on-verified"}):
                fail("invalid publishMode value")
            pipeline["publishMode"] = value
            idx += 1
            continue
        if execution == "graph" and key == "strictEdges":
            pipeline["strictEdges"] = parse_bool_text(raw)
            idx += 1
            continue
        # Tool exposure is a property of the whole run, not of one stage.
        # Mixing modes across stages of a single run means the same repo is
        # brokered two different ways at once, so this is deliberately not a
        # per-stage field. See validate_stage, which rejects it there.
        if key == "ralphMode":
            value = parse_scalar_text(raw) or ""
            if value not in RALPH_MODES:
                fail(
                    "invalid ralphMode value "
                    f"{value!r} (expected one of: {', '.join(sorted(RALPH_MODES))})"
                )
            pipeline["ralphMode"] = value
            idx += 1
            continue
        if key == "tooling":
            if raw.strip() not in {"", "{}"}:
                fail("pipeline.tooling must use mapping syntax")
            pipeline["tooling"], idx = parse_tooling_block(lines, idx + 1, current_indent)
            continue
        if execution == "graph" and key == "verificationProfiles":
            if raw.strip() not in {"", "[]"}:
                fail("pipeline.verificationProfiles must use list syntax")
            pipeline["verificationProfiles"], idx = parse_verification_profiles(lines, idx + 1, current_indent)
            continue
        if execution == "graph" and key == "repairRounds":
            if raw.strip() not in {"", "{}"}:
                fail("pipeline.repairRounds must use mapping syntax")
            pipeline["repairRounds"], idx = parse_repair_rounds_block(lines, idx + 1, current_indent)
            continue
        if execution == "graph" and key == "maxReworkIterations":
            value = parse_scalar_text(raw)
            parsed = parse_int_text(value)
            if parsed < 1 or parsed > REWORK_ITERATIONS_HARD_MAX:
                fail(
                    "maxReworkIterations must be an integer between 1 and "
                    f"{REWORK_ITERATIONS_HARD_MAX}"
                )
            pipeline["maxReworkIterations"] = parsed
            idx += 1
            continue
        if strict_keys_enabled(execution):
            fail(f"unknown pipeline field {key!r}")
        idx += 1
    return pipeline, idx


def parse_todos(lines: list[str], start_idx: int, parent_indent: int, execution: str) -> tuple[list[dict], int]:
    return parse_items(lines, start_idx, parent_indent, "todo", execution)


# Public mode vocabulary (AGENTS.md): authored frontmatter says mode:, never
# the internal engine names. Workflows (kind: workflow) are always multi-stage
# so "standard" (single-agent, no pipeline/graph) is a plan-only mode; engine:
# remains a workflow-only legacy input (plans never had an "engine:" key).
WORKFLOW_MODES = {"sequential", "dependency"}
PLAN_MODES = {"standard", "sequential", "dependency"}
WORKFLOW_ENGINES = {"orchestration", "graph"}
MODE_TO_EXECUTION = {
    "standard": "standard",
    "sequential": "orchestration",
    "dependency": "graph",
}
WORKFLOW_EXECUTION_TO_MODE = {
    "orchestration": "sequential",
    "graph": "dependency",
}


def resolve_workflow_mode_and_execution(
    mode: str, engine: str, execution_present: bool, kind: str = ""
) -> tuple[str, str]:
    """Resolve public mode and internal execution for a plan or workflow header.

    Authored sources use mode: standard|sequential|dependency (workflows, which
    are always multi-stage, accept only sequential|dependency). Legacy engine:
    orchestration|graph is accepted only for workflows, maps to public mode,
    and emits one stderr warning. Both mode and engine together are invalid.
    execution: remains a permanently accepted legacy alias for plans (not
    resolved here; see the direct execution: handling in parse_frontmatter).
    Mapping to execution happens for body parsing; serializers emit execution
    only on materialized plans, never engine.
    """
    if mode and engine:
        fail("mode and engine must not both be set; use mode: sequential|dependency only")
    if mode:
        allowed = WORKFLOW_MODES if kind == "workflow" else PLAN_MODES
        if mode not in allowed:
            fail(
                f"invalid mode value {mode!r}; "
                f"mode must be one of {', '.join(sorted(allowed))!s}"
            )
        if execution_present:
            fail("mode and execution must not both be set; use mode only")
        return mode, MODE_TO_EXECUTION[mode]
    if engine:
        if kind != "workflow":
            fail(
                "engine: is a workflow-only legacy key; add kind: workflow if this is "
                "meant to be a workflow, otherwise plans use mode: or execution:"
            )
        if engine not in WORKFLOW_ENGINES:
            fail(
                f"invalid engine value {engine!r}; "
                "engine must be 'graph' or 'orchestration'"
            )
        if execution_present:
            fail("engine and execution must not both be set; workflow sources use mode only")
        public_mode = WORKFLOW_EXECUTION_TO_MODE[engine]
        warn(f"legacy engine: {engine}; use mode: {public_mode} instead")
        return public_mode, engine
    return "", ""


def parse_workflow_defaults_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse optional top-level defaults: with exactly runtime and/or model."""
    defaults: dict = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key not in {"runtime", "model"}:
            fail(
                f"defaults: unknown field {key!r}; "
                "only runtime and model are permitted"
            )
        stripped = raw.strip()
        if stripped in {"[]", "{}"}:
            fail(f"defaults.{key}: must be a non-empty scalar")
        if stripped == "":
            peek = next_significant(lines, idx + 1)
            if peek < len(lines) and indent_of(lines[peek]) > current_indent:
                fail(f"defaults.{key}: must be a non-empty scalar")
            fail(f"defaults.{key}: must be a non-empty scalar")
        if stripped in BLOCK_INDICATORS:
            value, next_idx = parse_block_scalar(lines, idx, current_indent)
            if not str(value).strip():
                fail(f"defaults.{key}: must be a non-empty scalar")
            defaults[key] = value
            idx = next_idx
            continue
        value = parse_scalar_text(raw)
        if not value:
            fail(f"defaults.{key}: must be a non-empty scalar")
        defaults[key] = value
        idx += 1
    return defaults, idx


def validate_top_level_defaults(frontmatter: dict, workflow_source: bool) -> None:
    """Validate optional workflow defaults; reject defaults on non-workflow plans."""
    if not frontmatter.get("_defaults_present"):
        return
    if not workflow_source:
        fail("defaults: is only valid on workflow sources (kind: workflow)")
    defaults = frontmatter.get("defaults")
    if not isinstance(defaults, dict):
        fail("defaults: must be a mapping with only runtime and model")
    unknown = [key for key in defaults if key not in {"runtime", "model"}]
    if unknown:
        fail(
            f"defaults: unknown field {unknown[0]!r}; "
            "only runtime and model are permitted"
        )
    runtime = defaults.get("runtime", "")
    model = defaults.get("model", "")
    if "runtime" in defaults:
        if type(runtime) is not str or not runtime.strip():
            fail("defaults.runtime: must be a non-empty scalar")
        runtime = runtime.strip()
        if runtime not in ALLOWED_RUNTIMES:
            fail(f"defaults.runtime: invalid runtime {runtime!r}")
    if "model" in defaults:
        if type(model) is not str or not model.strip():
            fail("defaults.model: must be a non-empty scalar")
        if "runtime" not in defaults or not as_text(defaults.get("runtime", "")):
            fail("defaults.model: requires defaults.runtime")


def parse_plan_input_block(lines: list[str], start_idx: int, parent_indent: int) -> tuple[dict, int]:
    """Parse top-level planInput: {stage, required?} with required defaulting false."""
    plan_input: dict = {}
    idx = next_significant(lines, start_idx)
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        current_indent = indent_of(line)
        if current_indent <= parent_indent:
            break
        key, raw = split_key_value(line.strip())
        if key not in {"stage", "required"}:
            fail(
                f"planInput: unknown field {key!r}; "
                "only stage and required are permitted "
                "(no topology pruning or artifact-requirement waiver)"
            )
        stripped = raw.strip()
        if stripped in {"[]", "{}"}:
            fail(f"planInput.{key}: must be a scalar")
        if stripped == "":
            peek = next_significant(lines, idx + 1)
            if peek < len(lines) and indent_of(lines[peek]) > current_indent:
                fail(f"planInput.{key}: must be a scalar")
            fail(f"planInput.{key}: must be a scalar")
        if stripped in BLOCK_INDICATORS:
            value, next_idx = parse_block_scalar(lines, idx, current_indent)
            if key == "required":
                fail("planInput.required: must be a boolean scalar")
            if not str(value).strip():
                fail(f"planInput.{key}: must be a non-empty scalar")
            plan_input[key] = value
            idx = next_idx
            continue
        if key == "required":
            plan_input["required"] = parse_bool_text(raw)
            idx += 1
            continue
        value = parse_scalar_text(raw)
        if not value:
            fail(f"planInput.{key}: must be a non-empty scalar")
        plan_input[key] = value
        idx += 1
    if "stage" not in plan_input or not as_text(plan_input.get("stage", "")):
        fail("planInput.stage: required")
    stage_id = as_text(plan_input["stage"])
    if not STAGE_ID_RE.fullmatch(stage_id):
        fail(f"planInput.stage: invalid stage id {stage_id!r}")
    plan_input["stage"] = stage_id
    if "required" not in plan_input:
        plan_input["required"] = False
    elif plan_input["required"] not in (True, False):
        fail("planInput.required: must be a boolean")
    return plan_input, idx


def _text_has_input_plan_token(text: str) -> bool:
    for token in ARTIFACT_TOKEN_RE.findall(as_text(text)):
        if token.strip() == WORKFLOW_INPUT_PLAN_TOKEN:
            return True
    return False


def workflow_texts_with_input_plan(frontmatter: dict, stages: list, todos: list) -> list:
    """Return human-readable locations that contain {{INPUT_PLAN}}."""
    hits: list = []
    if _text_has_input_plan_token(frontmatter.get("instructions", "")):
        hits.append("frontmatter instructions")
    for todo in todos or []:
        if _text_has_input_plan_token(todo.get("content", "")):
            hits.append(f"{todo_prefix(todo)} content")
        if _text_has_input_plan_token(todo.get("verification", "")):
            hits.append(f"{todo_prefix(todo)} verification")
    for stage in stages or []:
        prefix = stage_prefix(stage)
        if _text_has_input_plan_token(stage.get("instructions", "")):
            hits.append(f"{prefix} instructions")
        for field_name in ("requires", "produces"):
            for index, item in enumerate(stage.get(field_name, []) or []):
                if not isinstance(item, dict):
                    continue
                path = as_text(item.get("path", ""))
                if _text_has_input_plan_token(path):
                    hits.append(f"{prefix} {field_name}[{index}].path")
        for voter in stage.get("voters", []) or []:
            if not isinstance(voter, dict):
                continue
            if _text_has_input_plan_token(voter.get("instructions", "")):
                voter_id = as_text(voter.get("id", "")) or "?"
                hits.append(f"{prefix} voter {voter_id} instructions")
    return hits


def validate_input_plan_token_usage(
    frontmatter: dict,
    stages: list,
    todos: list,
    workflow_source: bool,
    entry_mode: str,
) -> None:
    """Gate {{INPUT_PLAN}} to workflows with planInput; reject task-only paths that reach it."""
    hits = workflow_texts_with_input_plan(frontmatter, stages, todos)
    has_plan_input = bool(frontmatter.get("_plan_input_present"))
    if hits and not (workflow_source and has_plan_input):
        fail(
            "{{INPUT_PLAN}} is only valid in a workflow declaring planInput; "
            f"found in {hits[0]}"
        )
    if entry_mode == "workflow-instantiate" and hits:
        fail(
            "{{INPUT_PLAN}} cannot be reached on a task-only path without a supplied plan; "
            f"found in {hits[0]}"
        )


def validate_top_level_plan_input(
    frontmatter: dict,
    stages_by_id: dict,
    todos: list,
    workflow_source: bool,
) -> None:
    """Validate workflow-only planInput shape, consumer rules, and mutual exclusions."""
    if not frontmatter.get("_plan_input_present"):
        return
    if not workflow_source:
        fail(
            "planInput: is only valid on workflow sources (kind: workflow); "
            "reject on non-workflows and legacy materialized plans"
        )
    plan_input = frontmatter.get("planInput")
    if not isinstance(plan_input, dict):
        fail("planInput: must be a mapping with only stage and required")
    unknown = [key for key in plan_input if key not in {"stage", "required"}]
    if unknown:
        fail(
            f"planInput: unknown field {unknown[0]!r}; "
            "only stage and required are permitted "
            "(no topology pruning or artifact-requirement waiver)"
        )
    stage_id = as_text(plan_input.get("stage", ""))
    if not stage_id:
        fail("planInput.stage: required")
    if stage_id not in stages_by_id:
        fail(f"planInput.stage: unknown stage {stage_id!r}")
    required = plan_input.get("required", False)
    if required not in (True, False):
        fail("planInput.required: must be a boolean")
    stage = stages_by_id[stage_id]
    prefix = f"planInput stage {stage_id}"
    forbid_label = _stage_forbids_planner_plan_from(stage)
    if forbid_label:
        fail(f"{prefix}: ordinary stage required; {forbid_label} cannot be planInput")
    if not _is_ordinary_executable_agent_stage(stage):
        fail(f"{prefix}: must name an ordinary executable agent stage")
    has_planner = "planner" in stage and stage.get("planner") not in (None, "", {})
    if has_planner:
        fail(f"{prefix}: mutually exclusive with planner")
    plan_file = as_text(stage.get("planFile", ""))
    if plan_file:
        fail(f"{prefix}: mutually exclusive with planFile")
    plan_from = as_text(stage.get("planFrom", ""))
    if required:
        # May omit planFrom; once a supplied plan is bound the stage is plan-backed.
        pass
    else:
        if not plan_from:
            fail(
                f"{prefix}: optional planInput requires authored planFrom "
                "for task-mode starts"
            )
    for todo in todos or []:
        if as_text(todo.get("stage", "")) == stage_id:
            fail(
                f"{prefix}: plan-backed input stage must have no authored TODOs "
                f"(found {todo_prefix(todo)})"
            )
    # Single consumer: exactly one named stage; selecting a supplied plan replaces
    # only that stage's source binding and never waives dependsOn/artifacts.
    depends_on = stage.get("dependsOn") or []
    if depends_on and not isinstance(depends_on, list):
        fail(f"{prefix}: dependsOn must remain a list; planInput does not alter topology")


def prescan_workflow_header(lines: list[str]) -> dict:
    """Read order-independent top-level 'kind'/'mode'/'engine'/'execution' markers.

    Workflow sources declare their public mode (or legacy engine) authoritatively,
    and the pipeline parser needs the mapped execution before it reaches the
    'pipeline' block so dependency workflows get graph-only strict parsing
    regardless of key order.
    """
    header = {"kind": "", "mode": "", "engine": "", "_execution_present": False}
    for line in lines:
        if is_blank_or_comment(line):
            continue
        if indent_of(line) != 0:
            continue
        key, raw = split_key_value(line.strip())
        if key == "kind":
            header["kind"] = parse_scalar_text(raw)
        elif key == "mode":
            header["mode"] = parse_scalar_text(raw)
        elif key == "engine":
            header["engine"] = parse_scalar_text(raw)
        elif key == "execution":
            header["_execution_present"] = True
    return header


def parse_frontmatter(lines: list[str]) -> dict:
    data = {
        "name": "",
        "overview": "",
        "namespace": "",
        "instructions": "",
        "runtime": "",
        "model": "",
        "sessionStrategy": "",
        "isProject": False,
        "execution": "",
        "pipeline": {"stages": [], "parallelStages": []},
        "todos": [],
        "_pipeline_present": False,
        "_defaults_present": False,
        "_plan_input_present": False,
    }
    header = prescan_workflow_header(lines)
    data["kind"] = header["kind"]
    data["mode"] = ""
    data["engine"] = ""
    data["_execution_present"] = header["_execution_present"]
    if data["kind"] and data["kind"] != "workflow":
        fail(f"invalid kind value {data['kind']!r}; only 'workflow' is supported")
    # Resolve mode/engine whenever either is present so order-independent
    # validation runs before the body parser (even if kind is still missing).
    if header["mode"] or header["engine"]:
        public_mode, internal_execution = resolve_workflow_mode_and_execution(
            header["mode"], header["engine"], data["_execution_present"], data["kind"]
        )
        data["mode"] = public_mode
        data["execution"] = internal_execution
        # Keep legacy engine only when it was the authored key (warning path).
        if header["engine"] and not header["mode"]:
            data["engine"] = header["engine"]
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if is_blank_or_comment(line):
            idx += 1
            continue
        if indent_of(line) != 0:
            idx += 1
            continue
        key, raw = split_key_value(line.strip())
        if key in {"name", "overview", "namespace", "instructions"}:
            if key == "instructions" and raw.strip() in BLOCK_INDICATORS:
                data[key], idx = parse_block_scalar(lines, idx, 0)
            else:
                data[key] = parse_scalar_text(raw)
                idx += 1
            continue
        if key in {"runtime", "model", "sessionStrategy"}:
            # Leaf YAML plans (including generated planner plans) may freeze
            # effective defaults at the plan header. Workflows use defaults:.
            if data.get("kind") == "workflow":
                fail(
                    f"workflow files must not declare top-level {key!r}; "
                    "use defaults: {runtime, model} instead"
                )
            if raw.strip() in BLOCK_INDICATORS:
                fail(f"{key}: must be a scalar")
            data[key] = parse_scalar_text(raw)
            idx += 1
            continue
        if key == "isProject":
            data[key] = parse_bool_text(raw)
            idx += 1
            continue
        if key in {"kind", "mode", "engine"}:
            # Resolved order-independently by prescan_workflow_header.
            idx += 1
            continue
        if key == "execution":
            value = parse_scalar_text(raw)
            if value and value not in {"simple", "standard", "structured", "orchestration", "graph"}:
                fail(f"invalid execution value {value!r}")
            data["execution"] = value
            idx += 1
            continue
        if key == "defaults":
            if raw.strip() not in {"", "{}"}:
                fail("defaults must use mapping syntax")
            data["_defaults_present"] = True
            data["defaults"], idx = parse_workflow_defaults_block(lines, idx + 1, 0)
            continue
        if key == "planInput":
            if raw.strip() not in {"", "{}"}:
                fail("planInput must use mapping syntax")
            data["_plan_input_present"] = True
            data["planInput"], idx = parse_plan_input_block(lines, idx + 1, 0)
            continue
        if key == "pipeline":
            if raw.strip() not in {"", "{}"}:
                fail("pipeline must use mapping syntax")
            data["_pipeline_present"] = True
            data["pipeline"], idx = parse_pipeline(lines, idx + 1, 0, data["execution"])
            continue
        if key == "todos":
            if raw.strip() not in {"", "[]"}:
                fail("todos must use list syntax")
            data["todos"], idx = parse_todos(lines, idx + 1, 0, data["execution"])
            continue
        if strict_keys_enabled(data["execution"]):
            fail(f"unknown frontmatter field {key!r}")
        idx += 1
    return data


def normalize_artifacts(items: list[dict]) -> list[dict]:
    merged = []
    index = {}
    for item in items:
        path = item["path"]
        required = bool(item.get("required", True))
        if path in index:
            if required:
                merged[index[path]]["required"] = True
            continue
        index[path] = len(merged)
        merged.append({"path": path, "required": required})
    return merged


def raw_artifacts(items: list[dict]) -> list[dict]:
    result = []
    for item in items:
        entry = {"path": item["path"], "required": bool(item.get("required", True))}
        schema = as_text(item.get("schema", ""))
        if schema:
            entry["schema"] = schema
        result.append(entry)
    return result


def normalize_loop_check(obj: dict) -> dict:
    path = parse_scalar_text(str(obj.get("path", ""))) if obj.get("path") is not None else ""
    schema = parse_scalar_text(str(obj.get("schema", ""))) if obj.get("schema") is not None else ""
    result = {}
    if path:
        result["path"] = path
    if schema:
        result["schema"] = schema
    return result


def substitute_voter_id_in_artifacts(items: list, voter_id: str) -> list:
    """Return a copy of an artifact list with {{VOTER_ID}} substituted in every path."""
    result = []
    for item in items:
        path = as_text(item.get("path", ""))
        if "{{VOTER_ID}}" in path:
            item = {**item, "path": path.replace("{{VOTER_ID}}", voter_id)}
        result.append(item)
    return result


def graph_stage_producer_id(stage: dict, voter_id: str = "") -> str:
    stage_id = as_text(stage.get("id", ""))
    if voter_id:
        return f"{stage_id}:{voter_id}"
    return stage_id


def build_graph_artifact_maps(stages: list[dict], todos: list[dict]) -> tuple[dict, list[dict]]:
    """Map producers/consumers from stage and TODO declarations only.

    Roles never supply produces, requires, handoffs, or completion evidence.
    A stage with no produces invents no outputs; routing stays stage-declared.
    """
    producers = {}
    external_preconditions = []

    def register_producer(path: str, producer_id: str, context: str) -> None:
        existing = producers.get(path)
        if existing and existing != producer_id:
            fail(f"{context}: duplicate producer for {path!r} from {existing} and {producer_id}")
        producers[path] = producer_id

    for stage in stages:
        stage_id = as_text(stage.get("id", ""))
        for item in stage.get("produces", []):
            path = as_text(item.get("path", ""))
            if not path:
                continue
            register_producer(path, graph_stage_producer_id(stage), f"stage {stage_id}")
        for item in stage.get("requires", []):
            path = as_text(item.get("path", ""))
            if not path or path in producers:
                continue
            external_preconditions.append({"path": path, "consumer": stage_id})

        if as_text(stage.get("type", "")) == "consensus":
            for voter in stage.get("voters", []):
                voter_id = as_text(voter.get("id", ""))
                if not voter_id:
                    continue
                for item in stage.get("produces", []):
                    path = as_text(item.get("path", ""))
                    if not path:
                        continue
                    if "{{VOTER_ID}}" in path:
                        register_producer(
                            path.replace("{{VOTER_ID}}", voter_id),
                            graph_stage_producer_id(stage, voter_id),
                            f"stage {stage_id}",
                        )

    for todo in todos:
        todo_id = as_text(todo.get("id", ""))
        stage_id = as_text(todo.get("stage", ""))
        # Staged TODO produces belong to the stage node; only unstaged TODOs
        # register as their own producer ids.
        producer_id = stage_id or todo_id or f"todo:{todo.get('ordinal', 0)}"
        producer_ctx = f"stage {stage_id}" if stage_id else f"todo {todo_id or todo.get('ordinal', 0)}"
        consumer_id = stage_id or todo_id or f"todo:{todo.get('ordinal', 0)}"
        for item in todo.get("produces", []):
            path = as_text(item.get("path", ""))
            if not path:
                continue
            register_producer(path, producer_id, producer_ctx)
        for item in todo.get("requires", []):
            path = as_text(item.get("path", ""))
            if not path or path in producers:
                continue
            external_preconditions.append({"path": path, "consumer": consumer_id})

    return producers, external_preconditions


VALID_EDGE_CONDITIONS = {"passed", "changes-required", "error"}


def _parse_dep_entry(dep) -> tuple:
    """Parse a dependsOn entry into (dep_id, condition). condition is empty for unconditional edges."""
    if isinstance(dep, dict):
        dep_id = as_text(dep.get("id", ""))
        condition = as_text(dep.get("condition", ""))
        if condition and condition not in VALID_EDGE_CONDITIONS:
            fail(f"invalid edge condition '{condition}' for dependsOn entry {dep_id!r}; must be one of passed, changes-required, error")
        return dep_id, condition
    return as_text(dep), ""


def build_graph_edges(stages: list, todos: list, producers: dict, edge_derivation: str, strict_edges: bool) -> list:
    nodes = []
    node_index = {}
    node_kinds = {}
    declared_by_key = {}
    derived_by_key = {}

    def add_node(node_id: str, kind: str) -> None:
        if not node_id or node_id in node_index:
            return
        node_index[node_id] = len(nodes)
        nodes.append(node_id)
        node_kinds[node_id] = kind

    def edge_key(source: str, target: str, condition: str = "") -> str:
        return f"{source}\0{target}\0{condition}"

    def add_edge(store: dict, source: str, target: str, reason: str, condition: str = "") -> None:
        if not source or not target:
            return
        key = edge_key(source, target, condition)
        edge = store.get(key)
        if edge is None:
            edge = {"from": source, "to": target, "reasons": [], "condition": condition}
            store[key] = edge
        if reason not in edge["reasons"]:
            edge["reasons"].append(reason)

    def add_declared_edge(source: str, target: str, condition: str = "") -> None:
        if edge_derivation == "artifacts":
            return
        add_edge(declared_by_key, source, target, "declared", condition)

    def add_derived_edge(source: str, target: str, path: str) -> None:
        if edge_derivation == "declared":
            return
        add_edge(derived_by_key, source, target, f"artifact:{path}")

    for stage in stages:
        add_node(as_text(stage.get("id", "")), "stage")
    for todo in todos:
        add_node(as_text(todo.get("id", "")), "todo")

    for stage in stages:
        stage_id = as_text(stage.get("id", ""))
        for dep in stage.get("dependsOn", []):
            dep_id, dep_condition = _parse_dep_entry(dep)
            if dep_id:
                add_declared_edge(dep_id, stage_id, dep_condition)
        for item in stage.get("requires", []):
            path = as_text(item.get("path", ""))
            producer_id = as_text(producers.get(path, ""))
            if producer_id:
                add_derived_edge(producer_id, stage_id, path)

    for todo in todos:
        todo_id = as_text(todo.get("id", ""))
        for dep in todo.get("dependsOn", []):
            dep_id, dep_condition = _parse_dep_entry(dep)
            if dep_id:
                add_declared_edge(dep_id, todo_id, dep_condition)
        for item in todo.get("requires", []):
            path = as_text(item.get("path", ""))
            producer_id = as_text(producers.get(path, ""))
            if producer_id:
                add_derived_edge(producer_id, todo_id, path)

    if edge_derivation == "both":
        for key, edge in derived_by_key.items():
            if key in declared_by_key:
                for reason in edge["reasons"]:
                    if reason not in declared_by_key[key]["reasons"]:
                        declared_by_key[key]["reasons"].append(reason)
        edges_by_key = declared_by_key
        for key, edge in derived_by_key.items():
            if key not in edges_by_key:
                edges_by_key[key] = edge
    elif edge_derivation == "declared":
        edges_by_key = declared_by_key
    else:
        edges_by_key = derived_by_key

    adjacency = {node_id: [] for node_id in nodes}
    indegree = {node_id: 0 for node_id in nodes}
    for edge in edges_by_key.values():
        src = edge["from"]
        dst = edge["to"]
        if src not in adjacency:
            adjacency[src] = []
            indegree[src] = 0
            node_index[src] = len(nodes)
            nodes.append(src)
            node_kinds[src] = "unknown"
        if dst not in adjacency:
            adjacency[dst] = []
            indegree[dst] = 0
            node_index[dst] = len(nodes)
            nodes.append(dst)
            node_kinds[dst] = "unknown"
        adjacency[src].append(dst)
        indegree[dst] = indegree.get(dst, 0) + 1

    zero_inbound_nodes = [
        node_id
        for node_id in nodes
        if node_kinds.get(node_id) == "stage" and indegree.get(node_id, 0) == 0
    ]
    if len(zero_inbound_nodes) > 1:
        zero_inbound_text = ", ".join(zero_inbound_nodes)
        if strict_edges:
            fail("zero-inbound nodes: " + zero_inbound_text)
        warn("zero-inbound nodes: " + zero_inbound_text)

    queue = [node_id for node_id in nodes if indegree.get(node_id, 0) == 0]
    # Do not add a hidden sequential fallback edge for zero-inbound nodes; the
    # graph must stay inspectable so operators can see that multiple nodes start
    # together instead of being silently serialized.
    processed = []
    while queue:
        node_id = queue.pop(0)
        processed.append(node_id)
        for nxt in adjacency.get(node_id, []):
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                queue.append(nxt)

    if len(processed) != len(nodes):
        remaining = [node_id for node_id in nodes if indegree.get(node_id, 0) > 0]
        remaining_set = set(remaining)
        visiting = set()
        visited = set()
        stack = []

        def dfs(node_id: str):
            visiting.add(node_id)
            stack.append(node_id)
            for nxt in adjacency.get(node_id, []):
                if nxt not in remaining_set:
                    continue
                if nxt in visiting:
                    cycle_start = stack.index(nxt)
                    return stack[cycle_start:] + [nxt]
                if nxt not in visited:
                    result = dfs(nxt)
                    if result:
                        return result
            stack.pop()
            visiting.remove(node_id)
            visited.add(node_id)
            return None

        for node_id in remaining:
            if node_id in visited:
                continue
            cycle = dfs(node_id)
            if cycle:
                fail("cycle detected: " + " -> ".join(cycle))
        fail("cycle detected")

    edges = list(edges_by_key.values())
    # Remove the condition key from unconditional edges before output so the
    # schema remains backward-compatible with consumers that do not expect it.
    for _e in edges:
        if not _e.get("condition", ""):
            _e.pop("condition", None)
    edges.sort(key=lambda item: (node_index.get(item["from"], 0), node_index.get(item["to"], 0), item["from"], item["to"], item.get("condition", "")))
    return edges


def as_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)

ARTIFACT_TOKEN_RE = re.compile(r"\{\{([^{}]+)\}\}")
ABSOLUTE_ARTIFACT_PATH_RE = re.compile(r"(^/|^~|^[A-Za-z]:[\\/]|^\\\\)")
PARENT_TRAVERSAL_ARTIFACT_PATH_RE = re.compile(r"(^|/)\.\.(/|$)")
ALLOWED_ARTIFACT_TOKENS = {"ARTIFACT_NS", "PLAN_KEY", "STAGE_ID", "VOTER_ID"}


def todo_prefix(todo: dict, ordinal=None) -> str:
    todo_id = as_text(todo.get("id", ""))
    if todo_id:
        return f"todo {todo_id}"
    if ordinal is None:
        ordinal = todo.get("ordinal", "")
    return f"todo {ordinal}"


WORKFLOW_TASK_TOKEN = "TASK"
WORKFLOW_INPUT_PLAN_TOKEN = "INPUT_PLAN"


def validate_workflow_todo_tokens(todos: list, plan_input=None) -> None:
    """Workflow todo content may only use {{TASK}}, optional {{INPUT_PLAN}}, and artifact tokens."""
    allowed = ALLOWED_ARTIFACT_TOKENS | {WORKFLOW_TASK_TOKEN}
    if plan_input is not None:
        allowed |= {WORKFLOW_INPUT_PLAN_TOKEN}
    saw_task = False
    for todo in todos:
        content = as_text(todo.get("content", ""))
        for token in ARTIFACT_TOKEN_RE.findall(content):
            name = token.strip()
            if name == WORKFLOW_TASK_TOKEN:
                saw_task = True
                continue
            if name not in allowed:
                fail(
                    f"{todo_prefix(todo)}: unknown token {{{{{name}}}}} in content; "
                    f"workflow todos may only use {{{{TASK}}}} and artifact tokens"
                )
    if not saw_task:
        # Required plan-input workflows may have zero authored TODOs (the supplied
        # plan carries the loop). Optional / task-capable workflows still need {{TASK}}.
        if plan_input is not None and bool(plan_input.get("required")) and not todos:
            return
        fail("workflow requires at least one todo whose content contains {{TASK}}")


def stage_prefix(stage: dict, ordinal=None) -> str:
    stage_id = as_text(stage.get("id", ""))
    if stage_id:
        return f"stage {stage_id}"
    if ordinal is None:
        ordinal = stage.get("ordinal", "")
    return f"stage[{ordinal}]"


def validate_artifact_path(context: str, path: str) -> None:
    if not path:
        fail(f"{context}: artifact path must not be empty")
    for token in ARTIFACT_TOKEN_RE.findall(path):
        name = token.strip()
        # {{INPUT_PLAN}} is gated by validate_input_plan_token_usage (workflow + planInput).
        if name == WORKFLOW_INPUT_PLAN_TOKEN:
            continue
        if name not in ALLOWED_ARTIFACT_TOKENS:
            fail(f"{context}: unsupported token {{{{{name}}}}}")
    if ABSOLUTE_ARTIFACT_PATH_RE.search(path):
        fail(f"{context}: absolute paths are not portable")
    if PARENT_TRAVERSAL_ARTIFACT_PATH_RE.search(path):
        fail(f"{context}: parent traversal is not portable")


def validate_artifact_list(owner_prefix: str, owner: dict, field_name: str, items: list[dict]) -> None:
    if owner.get(f"__{field_name}_shorthand") is not None:
        fail(f"{owner_prefix} {field_name}: invalid artifact shorthand")
    for index, item in enumerate(items):
        item_prefix = f"{owner_prefix} {field_name}[{index}]"
        if item.get("__shorthand") is not None:
            fail(f"{item_prefix}: invalid artifact shorthand")
        path = as_text(item.get("path", ""))
        if not path:
            fail(f"{item_prefix}.path: missing path")
        validate_artifact_path(f"{item_prefix}.path", path)
        if "schema" in item:
            schema = as_text(item.get("schema", ""))
            if not schema:
                fail(f"{item_prefix}.schema: must be a non-empty string")
            validate_artifact_path(f"{item_prefix}.schema", schema)


def delegation_enabled(policy: dict) -> bool:
    return bool(policy and (
        as_text((policy.get("delegatedRuns") or {}).get("mode", "off")) != "off"
    ))


def validate_delegation(stage: dict, prefix: str, stage_type: str) -> None:
    policy = stage.get("delegation")
    if policy in (None, "", {}):
        return
    if not isinstance(policy, dict):
        fail(f"{prefix} delegation: must be an object")
    if "native" in policy:
        fail(
            f"{prefix} delegation.native: was removed. Use nativeSubagents: off|inherit. "
            f"Use current workflow fields (see DELEGATION.md)"
        )
    unknown = set(policy) - {"delegatedRuns"}
    if unknown:
        fail(f"{prefix} delegation: unknown fields: {', '.join(sorted(unknown))}")
    delegated = policy.get("delegatedRuns", {})
    if not isinstance(delegated, dict):
        fail(f"{prefix} delegation.delegatedRuns: must be an object")
    extra = set(delegated) - {"mode", "runtimes", "roles", "maxRuns", "maxParallel"}
    if extra:
        fail(f"{prefix} delegation.delegatedRuns: unknown fields: {', '.join(sorted(extra))}")
    mode = as_text(delegated.get("mode", "off"))
    if mode not in {"off", "read-only", "changeset"}:
        fail(f"{prefix} delegation.delegatedRuns.mode: must be off, read-only, or changeset")
    if mode == "off":
        extra_when_off = set(delegated) - {"mode"}
        if extra_when_off:
            fail(f"{prefix} delegation.delegatedRuns: only mode is allowed when mode is off")
    else:
        runtimes = delegated.get("runtimes")
        if (not isinstance(runtimes, list) or not runtimes or
                any(type(rt) is not str or rt not in ALLOWED_RUNTIMES for rt in runtimes)):
            fail(f"{prefix} delegation.delegatedRuns.runtimes: must be a non-empty array of supported runtimes")
        if len(runtimes) != len(set(runtimes)):
            fail(f"{prefix} delegation.delegatedRuns.runtimes: entries must be unique")
        roles = delegated.get("roles")
        if roles is not None:
            if (not isinstance(roles, list) or not roles or
                    any(type(role) is not str or not ROLE_ID_RE.fullmatch(role) for role in roles)):
                fail(f"{prefix} delegation.delegatedRuns.roles: must be a non-empty array of valid roles")
            if len(roles) != len(set(roles)):
                fail(f"{prefix} delegation.delegatedRuns.roles: entries must be unique")
        max_runs = delegated.get("maxRuns")
        if type(max_runs) is not int or max_runs <= 0:
            fail(f"{prefix} delegation.delegatedRuns.maxRuns: must be a positive integer")
        max_parallel = delegated.get("maxParallel")
        if type(max_parallel) is not int or max_parallel <= 0 or max_parallel > max_runs:
            fail(f"{prefix} delegation.delegatedRuns.maxParallel: must be a positive integer no greater than maxRuns")
        if mode == "changeset" and as_text(stage.get("workspaceMode", "shared") or "shared") not in {"snapshot", "worktree"}:
            fail(f"{prefix} delegation.delegatedRuns.mode: changeset requires workspaceMode snapshot or worktree")
    special = stage_type in {
        "consensus",
        "join",
        "router",
        "checkpoint",
        "gate",
        "integrate",
        "adjudicator",
        "approval",
    } or stage.get("grader") is True
    if special and delegation_enabled(policy):
        fail(f"{prefix} delegation: special stages cannot enable delegation")


def resolved_delegation(stage: dict) -> dict:
    """Return the frozen delegated-runs policy with explicit defaults."""
    policy = stage.get("delegation") or {}
    delegated = dict(policy.get("delegatedRuns") or {})
    defaults = {"mode": "off", "runtimes": [], "roles": [], "maxRuns": 0, "maxParallel": 0}
    defaults.update(delegated)
    return {"delegatedRuns": defaults}


def _stage_forbids_planner_plan_from(stage: dict) -> str:
    """Return a label when planner/planFrom are prohibited on this stage, else ''."""
    stage_type = as_text(stage.get("type", ""))
    if stage_type in SUPERVISOR_STAGE_TYPES:
        return f"{stage_type} nodes"
    if stage_type == "consensus":
        return "consensus stages"
    if stage_type == "adjudicator":
        return "adjudicator stages"
    if stage.get("grader") is True:
        return "grader stages"
    if stage.get("router") not in (None, "", {}):
        return "router stages"
    return ""


def _is_ordinary_executable_agent_stage(stage: dict) -> bool:
    stage_type = as_text(stage.get("type", ""))
    if stage_type not in {"", "agent", "stage"}:
        return False
    if stage.get("grader") is True:
        return False
    if stage.get("router") not in (None, "", {}):
        return False
    return True


def _planner_required_json_artifacts(stage: dict) -> list:
    """Required .json produces entries that declare the planner-output schema."""
    matches = []
    for item in stage.get("produces", []) or []:
        if not isinstance(item, dict):
            continue
        if item.get("required", True) is False:
            continue
        path = as_text(item.get("path", ""))
        schema = as_text(item.get("schema", ""))
        if path.endswith(".json") and schema == PLANNER_OUTPUT_SCHEMA:
            matches.append(item)
    return matches


def validate_planner_config(planner, prefix: str) -> dict:
    """Validate authored planner mapping; maxTodos defaults to 100, bound 1..200."""
    if not isinstance(planner, dict):
        fail(f"{prefix} planner: must be a mapping")
    for key in REMOVED_PLANNER_KEYS:
        if key in planner:
            fail(f"{prefix} planner.{key}: {REMOVED_PLANNER_GUIDANCE}")
    unknown = [key for key in planner if key not in {"outputMode", "maxTodos"}]
    if unknown:
        fail(
            f"{prefix} planner: unknown field {unknown[0]!r}; "
            "only outputMode and maxTodos are permitted"
        )
    output_mode = as_text(planner.get("outputMode", ""))
    if output_mode != "plan-file":
        fail(f"{prefix} planner.outputMode: must be plan-file")
    if "maxTodos" in planner:
        max_todos = planner.get("maxTodos")
        if type(max_todos) is not int or isinstance(max_todos, bool):
            fail(f"{prefix} planner.maxTodos: must be an integer between 1 and 200")
        if max_todos < 1 or max_todos > PLANNER_HARD_MAX_TODOS:
            fail(f"{prefix} planner.maxTodos: must be an integer between 1 and 200")
    else:
        max_todos = PLANNER_DEFAULT_MAX_TODOS
    return {"outputMode": "plan-file", "maxTodos": max_todos}


def validate_stage_planner_plan_from_fields(stage: dict, prefix: str) -> None:
    """Per-stage planner/planFrom shape, mutex, and prohibited-node checks."""
    has_planner = "planner" in stage and stage.get("planner") not in (None, "", {})
    plan_from = as_text(stage.get("planFrom", ""))
    plan_file = as_text(stage.get("planFile", ""))
    forbid_label = _stage_forbids_planner_plan_from(stage)

    if has_planner:
        if forbid_label:
            fail(f"{prefix} planner: {forbid_label} cannot declare planner")
        if plan_from:
            fail(f"{prefix} planner: mutually exclusive with planFrom")
        validate_planner_config(stage.get("planner"), prefix)

    if plan_from:
        if forbid_label:
            fail(f"{prefix} planFrom: {forbid_label} cannot declare planFrom")
        if not _is_ordinary_executable_agent_stage(stage):
            fail(f"{prefix} planFrom: only ordinary executable agent stages may declare planFrom")
        if plan_file:
            fail(f"{prefix} planFrom: mutually exclusive with planFile")
        if has_planner:
            fail(f"{prefix} planFrom: mutually exclusive with planner")
        if not STAGE_ID_RE.fullmatch(plan_from):
            fail(f"{prefix} planFrom: invalid stage id {plan_from!r}")


def validate_planner_plan_from_graph(stages_by_id: dict) -> None:
    """Cross-stage planFrom cardinality, direct-dependency, and artifact rules."""
    consumers_by_planner: dict[str, list[str]] = {}
    planner_artifact_owners: dict[str, list[str]] = {}

    for stage_id, stage in stages_by_id.items():
        prefix = f"stage {stage_id}"
        has_planner = "planner" in stage and stage.get("planner") not in (None, "", {})
        if has_planner:
            matches = _planner_required_json_artifacts(stage)
            if len(matches) != 1:
                fail(
                    f"{prefix} planner: must declare exactly one required .json artifact "
                    f"with schema {PLANNER_OUTPUT_SCHEMA}"
                )
            artifact_path = as_text(matches[0].get("path", ""))
            planner_artifact_owners.setdefault(artifact_path, []).append(stage_id)

        plan_from = as_text(stage.get("planFrom", ""))
        if not plan_from:
            continue
        if plan_from not in stages_by_id:
            fail(f"{prefix} planFrom: unknown stage {plan_from!r}")
        dep_ids = {
            _parse_dep_entry(item)[0]
            for item in (stage.get("dependsOn") or [])
            if _parse_dep_entry(item)[0]
        }
        if plan_from not in dep_ids:
            fail(
                f"{prefix} planFrom: {plan_from!r} must be a direct dependsOn dependency"
            )
        producer = stages_by_id[plan_from]
        producer_planner = producer.get("planner")
        if producer_planner in (None, "", {}):
            fail(
                f"{prefix} planFrom: {plan_from!r} must declare planner with "
                "outputMode plan-file"
            )
        normalized = validate_planner_config(producer_planner, f"stage {plan_from}")
        if normalized["outputMode"] != "plan-file":
            fail(
                f"{prefix} planFrom: {plan_from!r} must declare planner with "
                "outputMode plan-file"
            )
        producer_matches = _planner_required_json_artifacts(producer)
        if len(producer_matches) != 1:
            fail(
                f"{prefix} planFrom: planner {plan_from!r} must declare exactly one "
                f"required .json artifact with schema {PLANNER_OUTPUT_SCHEMA}"
            )
        consumers_by_planner.setdefault(plan_from, []).append(stage_id)

    for artifact_path, owners in planner_artifact_owners.items():
        if len(owners) > 1:
            fail(
                f"planner artifact {artifact_path!r}: must have a unique planner "
                f"producer; found stages {', '.join(owners)}"
            )

    for planner_id, consumer_ids in consumers_by_planner.items():
        if len(consumer_ids) > 1:
            fail(
                f"stage {planner_id} planner: must have at most one planFrom consumer; "
                f"found {', '.join(consumer_ids)}"
            )



def _stage_is_resettable_approval_target(stage: dict) -> bool:
    """True when stage may be named by approval.changesTarget (executable or planner)."""
    has_planner = "planner" in stage and stage.get("planner") not in (None, "", {})
    if has_planner:
        if _stage_forbids_planner_plan_from(stage):
            return False
        return True
    return _is_ordinary_executable_agent_stage(stage)


def _approval_upstream_ancestors(stage_id: str, stages_by_id: dict) -> set:
    """Stage ids reachable by walking dependsOn toward predecessors."""
    seen: set = set()
    stack = [stage_id]
    while stack:
        current = stack.pop()
        stage = stages_by_id.get(current)
        if stage is None:
            continue
        for dep in stage.get("dependsOn") or []:
            dep_id = _parse_dep_entry(dep)[0]
            if not dep_id or dep_id in seen:
                continue
            seen.add(dep_id)
            stack.append(dep_id)
    return seen


def _approval_downstream_closure(stage_id: str, stages_by_id: dict) -> set:
    """Stage ids that transitively depend on stage_id."""
    children: dict = {}
    for sid, stage in stages_by_id.items():
        for dep in stage.get("dependsOn") or []:
            dep_id = _parse_dep_entry(dep)[0]
            if dep_id:
                children.setdefault(dep_id, []).append(sid)
    seen: set = set()
    stack = [stage_id]
    while stack:
        current = stack.pop()
        for child in children.get(current, []):
            if child in seen:
                continue
            seen.add(child)
            stack.append(child)
    return seen


def validate_approval_stage_fields(stage: dict, prefix: str) -> None:
    """Local shape for public supervisor type: approval (no cross-stage checks)."""
    for key in stage:
        if key.startswith("__"):
            continue
        if key in APPROVAL_STAGE_FORBIDDEN_FIELDS:
            fail(
                f"{prefix} {key}: approval nodes reject agent, routing, tooling, plan, "
                "workspace, and Git fields"
            )
        if key not in APPROVAL_STAGE_ALLOWED_KEYS:
            fail(
                f"{prefix} {key}: unknown field on approval node; "
                "only question, changesTarget, dependsOn, and requires are permitted"
            )
    question = as_text(stage.get("question", ""))
    if not question:
        fail(f"{prefix} question: required non-empty text")
    changes_target = as_text(stage.get("changesTarget", ""))
    if not changes_target:
        fail(f"{prefix} changesTarget: required non-empty stage id")
    if not STAGE_ID_RE.fullmatch(changes_target):
        fail(f"{prefix} changesTarget: invalid stage id {changes_target!r}")
    depends_on = stage.get("dependsOn") or []
    if not isinstance(depends_on, list) or not depends_on:
        fail(f"{prefix} dependsOn: approval nodes require non-empty dependencies")
    if any(not _parse_dep_entry(item)[0] for item in depends_on):
        fail(f"{prefix} dependsOn: entries must be non-empty stage ids")
    requires = stage.get("requires") or []
    if not isinstance(requires, list) or not requires:
        fail(f"{prefix} requires: approval nodes must declare required artifacts to review")
    validate_artifact_list(prefix, stage, "requires", requires)
    if not any(
        isinstance(item, dict) and item.get("required", True) is not False for item in requires
    ):
        fail(f"{prefix} requires: at least one required artifact is mandatory")
    validate_instructions_allowed(stage, prefix, False, "approval nodes")


def validate_approval_changes_target(gate_id: str, stage: dict, stages_by_id: dict) -> None:
    """changesTarget must be one upstream executable/planner ancestor of the gate."""
    prefix = f"stage {gate_id}"
    target = as_text(stage.get("changesTarget", ""))
    if target == gate_id:
        fail(f"{prefix} changesTarget: cannot target self")
    if target not in stages_by_id:
        fail(f"{prefix} changesTarget: unknown stage {target!r}")
    target_stage = stages_by_id[target]
    target_type = as_text(target_stage.get("type", ""))
    if target_type in SUPERVISOR_STAGE_TYPES:
        fail(
            f"{prefix} changesTarget: supervisor {target_type} stage {target!r} "
            "is not a resettable target"
        )
    if not _stage_is_resettable_approval_target(target_stage):
        fail(
            f"{prefix} changesTarget: {target!r} must be an upstream executable or "
            "planner stage"
        )
    ancestors = _approval_upstream_ancestors(gate_id, stages_by_id)
    if target not in ancestors:
        if target in _approval_downstream_closure(gate_id, stages_by_id):
            fail(f"{prefix} changesTarget: {target!r} is downstream of the approval gate")
        fail(
            f"{prefix} changesTarget: {target!r} must be an ancestor whose downstream "
            "closure includes this approval gate"
        )
    if gate_id not in _approval_downstream_closure(target, stages_by_id):
        fail(
            f"{prefix} changesTarget: {target!r} must be an ancestor whose downstream "
            "closure includes this approval gate"
        )


def validate_approval_graph(stages_by_id: dict, todos: list) -> None:
    """Cross-stage approval ancestry and TODO refusal."""
    for stage_id, stage in stages_by_id.items():
        if as_text(stage.get("type", "")) != "approval":
            continue
        validate_approval_changes_target(stage_id, stage, stages_by_id)
    for todo in todos or []:
        stage_id = as_text(todo.get("stage", ""))
        if not stage_id or stage_id not in stages_by_id:
            continue
        if as_text(stages_by_id[stage_id].get("type", "")) == "approval":
            fail(f"{todo_prefix(todo)} stage: approval nodes do not take TODOs")


def validate_stage(stage: dict, ordinal: int, execution: str = "", workflow_source: bool = False) -> None:
    stage_id = as_text(stage.get("id", ""))
    prefix = stage_prefix(stage, ordinal)
    if not stage_id:
        fail(f"{prefix} id: missing stage id")
    if not STAGE_ID_RE.fullmatch(stage_id):
        fail(f"{prefix} id: invalid stage id format")
    stage_type = as_text(stage.get("type", ""))
    if stage_type and stage_type not in {
        "agent",
        "consensus",
        "join",
        "router",
        "checkpoint",
        "gate",
        "integrate",
        "adjudicator",
        "approval",
    }:
        fail(f"{prefix} type: invalid stage type {stage_type!r}")
    if stage_type == "approval":
        reject_stale_role(stage, prefix)
        validate_approval_stage_fields(stage, prefix)
        return
    plan_file = as_text(stage.get("planFile", ""))
    # Ordinary agent nodes (orchestration stages + graph agent/stage types) reject
    # profile-selecting agent and stale role. Consensus voters and repair
    # diagnose/lanes are handled separately below / at expand time.
    # Supervisor-owned types also reject role (scheduler-owned).
    agent_node_roles = execution == "orchestration" or (
        execution == "graph" and stage_type in {"", "agent", "stage"}
    )
    reject_stale_role(stage, prefix)
    if agent_node_roles:
        if "agent" in stage:
            fail(
                f"{prefix} agent: was removed. Use inline workflow instructions "
                f"(instructions: text)."
            )
        if "agentSource" in stage:
            fail(
                f"{prefix} agentSource: was removed. Use inline workflow instructions "
                f"(instructions: text)."
            )
    # Consensus container stages do not take agent; each voter owns its own
    # optional instructions with no inheritance from the stage or peers.
    if stage_type == "consensus":
        if "agent" in stage:
            fail(
                f"{prefix} agent: was removed. Set optional instructions: text on each voter. "
            )
        if "agentSource" in stage:
            fail(
                f"{prefix} agentSource: was removed. Set optional instructions: text on each voter. "
            )
    # Supervisor nodes do not invoke ambient native subagents; reject the field.
    if stage_type in SUPERVISOR_STAGE_TYPES and "nativeSubagents" in stage:
        fail(
            f"{prefix} nativeSubagents: {stage_type} nodes do not take nativeSubagents; "
            f"nativeSubagents is allowed on agent stages, consensus voters (forced off), "
            f"and repair diagnose/lanes"
        )
    if stage_type in SUPERVISOR_STAGE_TYPES and "subagents" in stage:
        fail(
            f"{prefix} subagents: was removed. Use nativeSubagents: off|inherit on agent stages "
            f"(supervisor {stage_type} nodes do not take nativeSubagents). "
            f"Use current workflow fields (see DELEGATION.md)"
        )
    # Inline instructions: agent stages (and repair diagnose/lanes elsewhere)
    # plus consensus voters only. Supervisors and consensus containers refuse.
    if stage_type in SUPERVISOR_STAGE_TYPES:
        validate_instructions_allowed(
            stage, prefix, False, f"{stage_type} nodes"
        )
    elif stage_type == "consensus":
        validate_instructions_allowed(
            stage, prefix, False, "consensus stages"
        )
    elif agent_node_roles or stage_type in {"", "agent", "stage"}:
        validate_instructions_allowed(
            stage, prefix, True, "agent stages"
        )
    else:
        validate_instructions_allowed(
            stage, prefix, False, f"{stage_type or 'this'} nodes"
        )
    if plan_file:
        validate_artifact_path(f"{prefix} planFile", plan_file)
        runtime = as_text(stage.get("runtime", ""))
        model = as_text(stage.get("model", ""))
        if runtime and runtime not in ALLOWED_RUNTIMES:
            fail(f"{prefix} runtime: invalid runtime {runtime!r}")
        # Model requires a resolvable effective runtime. Workflow sources may
        # leave runtime unset so invocation/workflow defaults fill it later;
        # materialized plans must already have a concrete runtime.
        if model and not runtime and not workflow_source:
            fail(f"{prefix} model: requires an effective runtime")
    else:
        runtime = as_text(stage.get("runtime", ""))
        model = as_text(stage.get("model", ""))
        if stage_type in {"", "agent"} and not runtime:
            if not workflow_source:
                fail(f"{prefix} runtime: missing runtime")
        if runtime and runtime not in ALLOWED_RUNTIMES:
            fail(f"{prefix} runtime: invalid runtime {runtime!r}")
        if model and not runtime and not workflow_source:
            fail(f"{prefix} model: requires an effective runtime")
        if not agent_node_roles:
            agent = as_text(stage.get("agent", ""))
            if stage_type in {"", "agent"} and not (agent or model):
                fail(f"{prefix} routing: must declare agent or model (or planFile for stage plan delegation)")
    session_strategy = as_text(stage.get("sessionStrategy", ""))
    if session_strategy and session_strategy not in ALLOWED_SESSION_STRATEGIES:
        fail(f"{prefix} sessionStrategy: invalid sessionStrategy {session_strategy!r}")
    grader = stage.get("grader", False)
    rubric = as_text(stage.get("rubric", ""))
    if grader not in (True, False, "", None):
        fail(f"{prefix} grader: must be a boolean")
    if grader is True:
        if not rubric:
            fail(f"{prefix} rubric: required when grader is true")
        validate_artifact_path(f"{prefix} rubric", rubric)
        if session_strategy and session_strategy != "fresh":
            fail(f"{prefix} sessionStrategy: grader stages require fresh")
        if stage.get("sessionResume") is True:
            fail(f"{prefix} sessionResume: grader stages cannot resume writer session")
    elif rubric:
        fail(f"{prefix} rubric: requires grader: true")
    router = stage.get("router")
    if router not in (None, "", {}):
        if not isinstance(router, dict):
            fail(f"{prefix} router: must be an object")
        allowed = router.get("allowedTargets")
        if not isinstance(allowed, list) or not allowed:
            fail(f"{prefix} router.allowedTargets: must be a non-empty array")
        if any(not as_text(item) for item in allowed):
            fail(f"{prefix} router.allowedTargets: entries must be non-empty strings")
        default_target = as_text(router.get("defaultTarget", ""))
        if not default_target:
            fail(f"{prefix} router.defaultTarget: required")
        terminal = router.get("terminalOutcomes") or []
        if terminal not in (None, []):
            if not isinstance(terminal, list):
                fail(f"{prefix} router.terminalOutcomes: must be an array")
            if any(not as_text(item) for item in terminal):
                fail(f"{prefix} router.terminalOutcomes: entries must be non-empty strings")
        on_invalid = as_text(router.get("onInvalid", "fail")) or "fail"
        if on_invalid not in {"fail", "default"}:
            fail(f"{prefix} router.onInvalid: must be fail or default")
        valid_targets = {as_text(item) for item in allowed} | {as_text(item) for item in terminal}
        if default_target not in valid_targets:
            fail(f"{prefix} router.defaultTarget: must appear in allowedTargets or terminalOutcomes")
        overlap = {as_text(item) for item in allowed} & {as_text(item) for item in terminal}
        if overlap:
            fail(f"{prefix} router: allowedTargets and terminalOutcomes must not overlap")
    context_budget = as_text(stage.get("contextBudget", ""))
    if context_budget and context_budget not in ALLOWED_CONTEXT_BUDGETS:
        fail(f"{prefix} contextBudget: invalid contextBudget {context_budget!r}")
    # Ordinary agent stages (and repair diagnose/lanes, which compile as agent)
    # use nativeSubagents: off|inherit (default off). Supervisor types already
    # rejected the field above. Consensus voters validate separately.
    if agent_node_roles:
        if "subagents" in stage:
            fail(
                f"{prefix} subagents: was removed. Use nativeSubagents: off|inherit. "
                f"Use current workflow fields (see DELEGATION.md)"
            )
        if "nativeSubagents" in stage:
            native_subagents = as_text(stage.get("nativeSubagents", ""))
            if not native_subagents or native_subagents not in ALLOWED_NATIVE_SUBAGENTS:
                fail(
                    f"{prefix} nativeSubagents: invalid nativeSubagents {native_subagents!r} "
                    f"(expected off or inherit)"
                )
    elif stage_type not in SUPERVISOR_STAGE_TYPES and stage_type != "consensus":
        # Adjudicator / other non-supervisor specials: reject legacy subagents;
        # allow nativeSubagents with the agent-stage contract when present.
        if "subagents" in stage:
            fail(
                f"{prefix} subagents: was removed. Use nativeSubagents: off|inherit. "
                f"Use current workflow fields (see DELEGATION.md)"
            )
        if "nativeSubagents" in stage:
            native_subagents = as_text(stage.get("nativeSubagents", ""))
            if not native_subagents or native_subagents not in ALLOWED_NATIVE_SUBAGENTS:
                fail(
                    f"{prefix} nativeSubagents: invalid nativeSubagents {native_subagents!r} "
                    f"(expected off or inherit)"
                )
    workspace_mode = as_text(stage.get("workspaceMode", ""))
    if workspace_mode and workspace_mode not in {"shared", "snapshot", "worktree"}:
        fail(f"{prefix} workspaceMode: must be shared, snapshot, or worktree")
    effective_workspace_mode = workspace_mode or "shared"
    if stage_type == "integrate" and effective_workspace_mode not in {"snapshot", "worktree"}:
        fail(f"{prefix} workspaceMode: integrate nodes require snapshot or worktree")
    git_access = as_text(stage.get("agentGitAccess", ""))
    if git_access and git_access not in {"inherit", "off", "on"}:
        fail(f"{prefix} agentGitAccess: must be inherit, off, or on")
    if git_access == "on" and os.environ.get("RALPH_GRAPH_GIT_SANDBOX_PROVEN", "") != "1":
        fail(f"{prefix} agentGitAccess: on requires a proved runtime sandbox boundary")
    parallel_mutation = as_text(stage.get("parallelMutation", ""))
    if parallel_mutation and parallel_mutation not in {"allow", "deny"}:
        fail(f"{prefix} parallelMutation: must be allow or deny")
    acknowledge_shared = stage.get("acknowledgeSharedMutationRisk", False)
    if acknowledge_shared not in (True, False, "", None):
        fail(f"{prefix} acknowledgeSharedMutationRisk: must be a boolean")
    write_scopes = stage.get("writeScopes", [])
    if write_scopes in (None, ""):
        write_scopes = []
    if not isinstance(write_scopes, list) or any(not as_text(item) for item in write_scopes):
        fail(f"{prefix} writeScopes: must be an array of non-empty project-relative globs")
    for scope in write_scopes:
        scope = as_text(scope)
        parts = scope.split("/")
        if scope.startswith("/") or "\\" in scope or ".." in parts or scope in {".", ""}:
            fail(f"{prefix} writeScopes: unsafe project-relative glob {scope!r}")
        if parts[0] in {".git", ".ralph", ".ralph-workspace"}:
            fail(f"{prefix} writeScopes: Ralph control and Git paths cannot be writable ({scope!r})")
    if effective_workspace_mode in {"snapshot", "worktree"} and not write_scopes and stage_type in {"", "agent", "stage"}:
        # An isolated stage without scopes is a read-only node. This is valid;
        # only nodes that opt into mutation by declaring scopes emit changesets.
        pass
    if effective_workspace_mode == "shared" and write_scopes:
        if parallel_mutation != "allow" or acknowledge_shared is not True:
            fail(f"{prefix} shared mutation requires parallelMutation: allow and acknowledgeSharedMutationRisk: true")
    if stage_type == "integrate" and write_scopes:
        fail(f"{prefix} writeScopes: integrate nodes are scheduler-owned and do not accept agent scopes")
    overlap_owner = as_text(stage.get("overlapOwner", ""))
    ownership_role = as_text(stage.get("ownershipRole", ""))
    if ownership_role and ownership_role not in {"integration", "repair"}:
        fail(f"{prefix} ownershipRole: must be integration or repair")
    if stage_type == "integrate" and ownership_role == "repair":
        fail(f"{prefix} ownershipRole: integrate nodes cannot declare the repair role")
    if overlap_owner and not write_scopes:
        fail(f"{prefix} overlapOwner: requires writeScopes")
    effective_git_access = git_access or ("off" if effective_workspace_mode == "worktree" else "inherit")
    if (effective_workspace_mode == "worktree" and write_scopes and
            effective_git_access == "off" and
            os.environ.get("RALPH_GRAPH_GIT_SANDBOX_PROVEN", "") != "1"):
        fail(f"{prefix} agentGitAccess: off for a mutating worktree requires a proved runtime sandbox boundary")
    setup_profile = as_text(stage.get("setupProfile", ""))
    if setup_profile and not re.fullmatch(r"[A-Za-z0-9._-]+", setup_profile):
        fail(f"{prefix} setupProfile: must contain only letters, digits, dot, underscore, or hyphen")
    validate_delegation(stage, prefix, stage_type)
    validate_stage_planner_plan_from_fields(stage, prefix)
    if "maxIterations" in stage and stage["maxIterations"] != "":
        max_iterations = stage["maxIterations"]
        if not isinstance(max_iterations, int) or max_iterations <= 0:
            fail(f"{prefix} maxIterations: must be a positive integer")
    quorum = stage.get("quorum", "")
    if quorum != "":
        if not isinstance(quorum, int) or quorum <= 0:
            fail(f"{prefix} quorum: must be a positive integer")
        # Research published in 2026 found correlated errors across AI providers
        # and an agreement-to-correctness Spearman correlation of only 0.20-0.59.
        # Three voters on the same runtime are really one voter. quorum without
        # minRuntimes of distinct providers gives a false sense of consensus.
        warn(
            f"{prefix} quorum: correlated-error research (2026, Spearman r=0.20-0.59) "
            f"shows agreement does not reliably predict correctness. "
            f"quorum requires minRuntimes of N distinct providers to provide independent signal; "
            f"same-runtime voters are correlated and do not count as independent evidence."
        )
        min_runtimes_val = stage.get("minRuntimes", "")
        if min_runtimes_val == "":
            fail(
                f"{prefix} quorum: minRuntimes is required when using quorum policy. "
                f"Three voters on the same runtime are effectively one voter. "
                f"Specify minRuntimes: N to require N distinct runtime providers."
            )
    min_runtimes = stage.get("minRuntimes", "")
    if min_runtimes != "":
        if not isinstance(min_runtimes, int) or min_runtimes <= 0:
            fail(f"{prefix} minRuntimes: must be a positive integer")
    if stage.get("voters") not in (None, ""):
        voters = stage.get("voters", [])
        if not isinstance(voters, list) or not voters:
            fail(f"{prefix} voters: must be a non-empty array")
        # A consensus node with fewer than two voters is a tautology: there is
        # nothing to compare, and the entire value of cross-provider consensus
        # comes from independent disagreement between at least two distinct
        # reviewers.
        if len(voters) < 2:
            fail(f"{prefix} voters: consensus nodes require at least two voters, got {len(voters)}")
        seen_voter_ids: set[str] = set()
        for voter_idx, voter in enumerate(voters, start=1):
            voter_prefix = f"{prefix} voters[{voter_idx}]"
            if not isinstance(voter, dict):
                fail(f"{voter_prefix}: must be an object")
            voter_id = as_text(voter.get("id", ""))
            if not voter_id:
                fail(f"{voter_prefix}.id: missing voter id")
            # Duplicate voter ids would produce two synthetic stages with
            # identical ids, which breaks the artifact map and the ledger.
            if voter_id in seen_voter_ids:
                fail(f"{prefix} voters: duplicate voter id {voter_id!r}")
            seen_voter_ids.add(voter_id)
            # Name the voter, not just its index: an operator edits voters by id.
            voter_prefix = f"{prefix} voters[{voter_idx}] ({voter_id})"
            if "agent" in voter:
                fail(
                    f"{voter_prefix} agent: was removed. Use inline workflow instructions "
                    f"(instructions: text)."
                )
            if "agentSource" in voter:
                fail(
                    f"{voter_prefix} agentSource: was removed. Use inline workflow instructions "
                    f"(instructions: text)."
                )
            reject_stale_role(voter, voter_prefix)
            for key in ("runtime", "model", "sessionStrategy", "contextBudget", "nativeSubagents"):
                if key in voter and not as_text(voter.get(key, "")):
                    fail(f"{voter_prefix}.{key}: must not be empty")
            if "instructions" in voter:
                validate_instructions_value(voter.get("instructions"), voter_prefix)
            if "subagents" in voter:
                fail(
                    f"{voter_prefix} subagents: was removed. Voters compile to nativeSubagents: off. "
                    f"Use current workflow fields (see DELEGATION.md)"
                )
            voter_native = as_text(voter.get("nativeSubagents", ""))
            if voter_native and voter_native not in ALLOWED_NATIVE_SUBAGENTS:
                fail(
                    f"{voter_prefix} nativeSubagents: invalid nativeSubagents {voter_native!r} "
                    f"(expected off or inherit)"
                )
            validate_delegation({**stage, **voter}, voter_prefix, "consensus")
            # Voters must not use ambient native subagents. The consensus result
            # schema records each voter's runtime and model as provenance,
            # and the entire value of the jury rests on those being an accurate
            # description of what produced the verdict. Native subagent fan-out
            # makes that provenance false and adds variance to the one
            # measurement that must be a clean independent sample. Authors who
            # need native inherit should use a separate agent node. This
            # restriction applies only to voters; ordinary agent stages (and
            # repair diagnose/lanes) keep the off|inherit contract.
            if voter_native and voter_native != "off":
                fail(
                    f"{prefix} voters[{voter_id}].nativeSubagents: voters must compile to "
                    f"nativeSubagents: off (got {voter_native!r}); ambient native subagents "
                    f"make the recorded provenance (runtime, model) inaccurate. "
                    f"Use a separate agent node for nativeSubagents: inherit."
                )
        # Validate that quorum policy has at least minRuntimes distinct runtime
        # providers across the voter set.  Three claude voters are really one
        # voter; the correlated-error protection only holds when voters run on
        # independently-implemented model providers.
        if quorum != "" and min_runtimes != "":
            distinct_runtimes: set[str] = set()
            for voter in voters:
                rt = as_text(voter.get("runtime", ""))
                if rt:
                    distinct_runtimes.add(rt)
            if len(distinct_runtimes) < int(min_runtimes):
                fail(
                    f"{prefix} quorum: minRuntimes={min_runtimes} requires at least "
                    f"{min_runtimes} distinct runtime providers, but the voter set only "
                    f"has {len(distinct_runtimes)} distinct runtime(s): "
                    f"{', '.join(sorted(distinct_runtimes))}. "
                    f"Same-runtime voters are correlated and do not provide independent evidence."
                )
    validate_artifact_list(prefix, stage, "requires", stage.get("requires", []))
    validate_artifact_list(prefix, stage, "produces", stage.get("produces", []))
    loop_check = normalize_loop_check(stage.get("loopCheck", {}))
    if loop_check.get("path"):
        validate_artifact_path(f"{prefix} loopCheck.path", loop_check["path"])


def validate_plan_header_routing(frontmatter: dict) -> str:
    """Validate optional leaf-plan header runtime/model/sessionStrategy.

    Returns the effective plan default runtime (may be empty).
    """
    plan_runtime = as_text(frontmatter.get("runtime", ""))
    plan_model = as_text(frontmatter.get("model", ""))
    plan_session = as_text(frontmatter.get("sessionStrategy", ""))
    if plan_runtime and plan_runtime not in ALLOWED_RUNTIMES:
        fail(f"frontmatter runtime: invalid runtime {plan_runtime!r}")
    if plan_model and not plan_runtime:
        fail("frontmatter model: requires an effective runtime")
    if plan_session and plan_session not in ALLOWED_SESSION_STRATEGIES:
        fail(f"frontmatter sessionStrategy: invalid sessionStrategy {plan_session!r}")
    return plan_runtime


def validate_todo(
    todo: dict,
    ordinal: int,
    stages_by_id: dict,
    plan_runtime: str = "",
    plan_session: str = "",
) -> None:
    stage = as_text(todo.get("stage", ""))
    runtime = as_text(todo.get("runtime", ""))
    agent = as_text(todo.get("agent", ""))
    model = as_text(todo.get("model", ""))
    session_strategy = as_text(todo.get("sessionStrategy", ""))
    context_budget = as_text(todo.get("contextBudget", ""))
    subagents = as_text(todo.get("subagents", ""))
    native_subagents = as_text(todo.get("nativeSubagents", ""))
    plan_rt = as_text(plan_runtime)
    plan_sess = as_text(plan_session)
    prefix = todo_prefix(todo, ordinal)
    reject_stale_role(todo, prefix)
    if runtime and runtime not in ALLOWED_RUNTIMES:
        fail(f"{prefix} runtime: invalid runtime {runtime!r}")
    if session_strategy and session_strategy not in ALLOWED_SESSION_STRATEGIES:
        fail(f"{prefix} sessionStrategy: invalid sessionStrategy {session_strategy!r}")
    if context_budget and context_budget not in ALLOWED_CONTEXT_BUDGETS:
        fail(f"{prefix} contextBudget: invalid contextBudget {context_budget!r}")
    if stage:
        # Staged TODOs follow graph/orchestration nativeSubagents; reject legacy
        # subagents with the same migration guidance as agent stages.
        if "subagents" in todo:
            fail(
                f"{prefix} subagents: was removed. Use nativeSubagents: off|inherit. "
                f"Use current workflow fields (see DELEGATION.md)"
            )
        if "nativeSubagents" in todo:
            if not native_subagents or native_subagents not in ALLOWED_NATIVE_SUBAGENTS:
                fail(
                    f"{prefix} nativeSubagents: invalid nativeSubagents {native_subagents!r} "
                    f"(expected off or inherit)"
                )
        # A staged TODO that switches runtime may also pin a model; runtime-only
        # selects that runtime's saved/native default.
        if stage not in stages_by_id:
            fail(f"{prefix} stage: unknown stage {stage!r}")
    else:
        # Standard (unstaged) TODOs: reject profile-selecting agent and stale role.
        if "agent" in todo:
            fail(
                f"{prefix} agent: was removed. Use inline workflow instructions "
                f"(instructions: text)."
            )
        if "subagents" in todo:
            fail(
                f"{prefix} subagents: was removed. Use nativeSubagents: off|inherit. "
                f"Use current workflow fields (see DELEGATION.md)"
            )
        if "nativeSubagents" in todo:
            if not native_subagents or native_subagents not in ALLOWED_NATIVE_SUBAGENTS:
                fail(
                    f"{prefix} nativeSubagents: invalid nativeSubagents {native_subagents!r} "
                    f"(expected off or inherit)"
                )
        routing_fields = [runtime, model, session_strategy, context_budget, native_subagents]
        if any(routing_fields) and not runtime:
            # Model-only inherits the plan frontmatter effective runtime (generated
            # Ralph plans and supplied leaf plans), matching staged-TODO inheritance.
            model_only = bool(model) and not any(
                [session_strategy, context_budget, native_subagents]
            )
            if model_only and plan_rt:
                pass
            else:
                fail(
                    f"{prefix} routing: unstaged TODOs require an effective runtime "
                    "(TODO runtime or plan frontmatter runtime) when declaring routing overrides"
                )
    # A TODO that switches away from its baseline runtime (stage runtime for
    # staged TODOs, plan header runtime for standard/generated TODOs) must run
    # in a fresh session so no prior-runtime context leaks across runtimes.
    # Unset sessionStrategy defaults to fresh.
    if runtime:
        stage_obj = stages_by_id.get(stage) if stage else None
        baseline_runtime = as_text((stage_obj or {}).get("runtime", "")) or plan_rt
        baseline_session = as_text((stage_obj or {}).get("sessionStrategy", "")) or plan_sess
        if baseline_runtime and runtime != baseline_runtime:
            effective_session = session_strategy or baseline_session or "fresh"
            if effective_session != "fresh":
                fail(
                    f"{prefix} runtime: switching runtime from {baseline_runtime!r} to "
                    f"{runtime!r} requires effective sessionStrategy: fresh "
                    f"(got {effective_session!r})"
                )
    validate_artifact_list(prefix, todo, "requires", todo.get("requires", []))
    validate_artifact_list(prefix, todo, "produces", todo.get("produces", []))


def resolve_target(items: list[dict], target: str) -> dict:
    id_matches = [item for item in items if as_text(item.get("id", "")) == target]
    if len(id_matches) > 1:
        fail(f"duplicate todo id {target!r}")
    if len(id_matches) == 1:
        return id_matches[0]
    if target.isdigit():
        ordinal = int(target)
        ordinal_matches = [item for item in items if item.get("ordinal") == ordinal]
        if len(ordinal_matches) != 1:
            fail(f"todo ordinal {target!r} not found")
        return ordinal_matches[0]
    fail(f"todo {target!r} not found")


def resolve_stage_map(stages: list[dict], execution: str = "", workflow_source: bool = False) -> dict:
    seen = {}
    for ordinal, stage in enumerate(stages, start=1):
        validate_stage(stage, ordinal, execution, workflow_source=workflow_source)
        stage_id = as_text(stage.get("id", ""))
        if stage_id in seen:
            fail(f"{stage_prefix(stage, ordinal)} id: duplicate stage id")
        seen[stage_id] = stage
    return seen


def stage_defaults_for(todo: dict, stages_by_id: dict) -> dict:
    stage_id = as_text(todo.get("stage", ""))
    if not stage_id:
        return {}
    stage = stages_by_id.get(stage_id)
    if stage is None:
        fail(f"{todo_prefix(todo)} stage: unknown stage {stage_id!r}")
    return stage


def validate_parallel_stages(pipeline: dict, stages_by_id: dict) -> None:
    waves = pipeline.get("parallelStages", [])
    if waves is None:
        return
    if not isinstance(waves, list):
        fail("pipeline.parallelStages: must be an array of stage waves")
    seen_stage_ids = set()
    for wave_idx, wave in enumerate(waves, start=1):
        wave_prefix = f"pipeline.parallelStages[{wave_idx}]"
        if not isinstance(wave, list):
            fail(f"{wave_prefix}: must be an array of stage ids")
        for stage_idx, stage_id in enumerate(wave, start=1):
            stage_name = as_text(stage_id)
            if not stage_name:
                fail(f"{wave_prefix}[{stage_idx}]: empty stage id")
            if stage_name not in stages_by_id:
                fail(f"{wave_prefix}[{stage_idx}]: unknown stage {stage_name!r}")
            if stage_name in seen_stage_ids:
                fail(f"{wave_prefix}[{stage_idx}]: duplicate stage {stage_name!r} across parallel waves")
            seen_stage_ids.add(stage_name)


def _stage_is_agent_node(stage: dict) -> bool:
    stage_type = as_text(stage.get("type", ""))
    return stage_type in {"", "agent", "stage"}


def _stage_has_effective_routing(stage: dict) -> bool:
    # Ordinary agent nodes require a runtime; optional model is a routing pin.
    # or model overrides, not routing gates.
    return bool(as_text(stage.get("runtime", "")))


def validate_loop_rules(
    stage: dict,
    ordinal: int,
    stages_by_id: dict,
    stage_effective_produces: dict,
    stage_raw_produces: dict,
    execution: str,
    max_rework_iterations,
    all_stages: list,
    reserved_ids: set,
    workflow_source: bool = False,
) -> None:
    prefix = stage_prefix(stage, ordinal)
    stage_id = as_text(stage.get("id", ""))
    loop_back = as_text(stage.get("loopBackTo", ""))
    max_iterations = stage.get("maxIterations", "")
    loop_check = normalize_loop_check(stage.get("loopCheck", {}))

    on_exhausted = as_text(stage.get("onExhausted", ""))

    if loop_check.get("path"):
        validate_artifact_path(f"{prefix} loopCheck.path", loop_check["path"])
    if loop_check.get("schema"):
        validate_artifact_path(f"{prefix} loopCheck.schema", loop_check["schema"])

    if loop_back:
        if loop_back not in stages_by_id:
            fail(f"{prefix} loopBackTo: unknown stage {loop_back!r}")
        if not loop_check.get("path"):
            fail(f"{prefix} loopCheck.path: required when loopBackTo is set")

        effective_max_iterations = max_iterations
        if execution == "graph" and effective_max_iterations == "":
            if max_rework_iterations != "":
                effective_max_iterations = max_rework_iterations
            else:
                fail(
                    f"{prefix} maxIterations: required when loopBackTo is set; set "
                    "maxIterations on the stage or pipeline.maxReworkIterations as a "
                    "plan-wide default"
                )
        if (
            not isinstance(effective_max_iterations, int)
            or isinstance(effective_max_iterations, bool)
            or effective_max_iterations <= 0
        ):
            fail(f"{prefix} maxIterations: must be a positive integer")
        if execution == "graph" and effective_max_iterations > REWORK_ITERATIONS_HARD_MAX:
            fail(
                f"{prefix} maxIterations: effective rework iteration count "
                f"{effective_max_iterations} exceeds the hard maximum of "
                f"{REWORK_ITERATIONS_HARD_MAX}"
            )
        if on_exhausted and on_exhausted not in ("proceed", "fail"):
            fail(f"{prefix} onExhausted: must be 'proceed' or 'fail'")
    else:
        if max_iterations != "":
            fail(f"{prefix} maxIterations: requires loopBackTo")
        if loop_check.get("path"):
            fail(f"{prefix} loopCheck.path: requires loopBackTo")
        if loop_check.get("schema"):
            fail(f"{prefix} loopCheck.schema: requires loopBackTo")
        if on_exhausted:
            fail(f"{prefix} onExhausted: requires loopBackTo")

    if loop_check.get("path"):
        required_paths = {
            item["path"]
            for item in stage_effective_produces.get(stage_id, [])
            if item.get("required", True)
        }
        if loop_check["path"] not in required_paths:
            fail(f"{prefix} loopCheck.path: missing from required effective produces")

    if not (loop_back and execution == "graph"):
        return

    target = stages_by_id[loop_back]

    dep_ids = {_parse_dep_entry(item)[0] for item in (stage.get("dependsOn") or [])}
    if loop_back not in dep_ids:
        fail(
            f"{prefix} loopBackTo: {loop_back!r} must be a direct dependsOn dependency of "
            f"{stage_id!r} for graph rework; a transitive ancestor is not enough "
            "(direct dependency is required)"
        )

    if as_text(stage.get("planFile", "")):
        fail(
            f"{prefix} planFile: graph rework does not support planFile stages; "
            f"rewrite {stage_id!r} using inline TODOs"
        )
    if as_text(target.get("planFile", "")):
        fail(
            f"stage {loop_back} planFile: graph rework does not support planFile stages; "
            f"rewrite {loop_back!r} using inline TODOs"
        )
    # Planner stages emit JSON plans; they are never rework targets. Ordinary
    # planFrom (or provided-plan) consumers may be loopBackTo targets; the
    # review edge is feedback onto a fresh control copy of the same source.
    if "planner" in target and target.get("planner") not in (None, "", {}):
        fail(
            f"stage {loop_back} planner: graph rework loopBackTo target must not be a "
            f"planner stage; rework the planFrom (or provided-plan) consumer instead"
        )

    if loop_check.get("schema") != GRAPH_REWORK_EVALUATOR_SCHEMA:
        fail(
            f"{prefix} loopCheck.schema: graph rework requires "
            f"{GRAPH_REWORK_EVALUATOR_SCHEMA!r}"
        )
    produce_schemas = {
        as_text(item.get("schema", ""))
        for item in stage_raw_produces.get(stage_id, [])
        if item.get("path") == loop_check.get("path")
    }
    if GRAPH_REWORK_EVALUATOR_SCHEMA not in produce_schemas:
        fail(
            f"{prefix} produces[{loop_check.get('path')!r}].schema: must match loopCheck.schema "
            f"{GRAPH_REWORK_EVALUATOR_SCHEMA!r} for graph rework"
        )

    if not _stage_is_agent_node(stage):
        fail(
            f"{prefix} type: graph rework review stage must be an agent node "
            f"(type omitted, 'agent', or legacy 'stage'), got {as_text(stage.get('type', ''))!r}"
        )
    if not _stage_is_agent_node(target):
        fail(
            f"stage {loop_back} type: graph rework loopBackTo target must be an agent node "
            f"(type omitted, 'agent', or legacy 'stage'), got {as_text(target.get('type', ''))!r}"
        )
    if not workflow_source:
        if not _stage_has_effective_routing(stage):
            fail(f"{prefix} routing: graph rework review stage requires effective runtime")
        if not _stage_has_effective_routing(target):
            fail(
                f"stage {loop_back} routing: graph rework loopBackTo target requires effective "
                "runtime"
            )

    for other in all_stages:
        other_id = as_text(other.get("id", ""))
        if other_id == stage_id:
            continue
        for dep in other.get("dependsOn") or []:
            dep_id, dep_condition = _parse_dep_entry(dep)
            if dep_id == stage_id and dep_condition:
                fail(
                    f"stage {other_id} dependsOn {stage_id}: graph rework review stages own "
                    "their generated passed/changes-required branches; downstream dependsOn "
                    "edges onto a rework review must be unconditional"
                )

    candidate_ids = []
    for n in range(1, effective_max_iterations + 1):
        candidate_ids.append(f"{loop_back}-r{n}")
        candidate_ids.append(f"{stage_id}-r{n}")
    candidate_ids.append(f"{stage_id}-approved")
    for candidate in candidate_ids:
        if candidate in reserved_ids:
            fail(
                f"{prefix} loopBackTo: graph rework expansion id {candidate!r} collides with "
                "an authored stage id or another rework expansion"
            )
        reserved_ids.add(candidate)


def validate_write_scope_conflicts(stages: list[dict]) -> None:
    """Reject unordered overlaps unless one downstream integration/repair owner is explicit."""
    stages_by_id = {as_text(stage.get("id", "")): stage for stage in stages}
    dependencies = {
        as_text(stage.get("id", "")): {
            _parse_dep_entry(item)[0] for item in (stage.get("dependsOn") or []) if _parse_dep_entry(item)[0]
        }
        for stage in stages
    }

    def reaches(start: str, target: str, seen=None) -> bool:
        seen = set() if seen is None else seen
        if start in seen:
            return False
        seen.add(start)
        direct = dependencies.get(start, set())
        return target in direct or any(reaches(item, target, seen) for item in direct)

    def static_prefix(pattern: str) -> str:
        positions = [pattern.find(char) for char in "*?[" if char in pattern]
        end = min(positions) if positions else len(pattern)
        return pattern[:end].rstrip("/")

    def overlaps(left: str, right: str) -> bool:
        a, b = static_prefix(left), static_prefix(right)
        if not a or not b:
            return True
        return a == b or a.startswith(b + "/") or b.startswith(a + "/")

    mutating = [stage for stage in stages if stage.get("writeScopes")]
    for index, left in enumerate(mutating):
        left_id = as_text(left.get("id", ""))
        for right in mutating[index + 1:]:
            right_id = as_text(right.get("id", ""))
            if reaches(left_id, right_id) or reaches(right_id, left_id):
                continue
            for left_scope in left.get("writeScopes", []):
                for right_scope in right.get("writeScopes", []):
                    if overlaps(as_text(left_scope), as_text(right_scope)):
                        owner_id = as_text(left.get("overlapOwner", ""))
                        if owner_id and owner_id == as_text(right.get("overlapOwner", "")):
                            owner = stages_by_id.get(owner_id)
                            role = as_text((owner or {}).get("ownershipRole", ""))
                            owner_type = as_text((owner or {}).get("type", "")) or "agent"
                            owner_is_explicit = role in {"integration", "repair"}
                            owner_matches_type = (
                                (role == "integration" and owner_type == "integrate") or
                                (role == "repair" and owner_type in {"agent", "stage"})
                            )
                            if owner_is_explicit and owner_matches_type and reaches(owner_id, left_id) and reaches(owner_id, right_id):
                                continue
                        fail(
                            f"graph writeScopes overlap on unordered nodes {left_id!r} and {right_id!r}: "
                            f"{left_scope!r} vs {right_scope!r}; assign both to one downstream "
                            "overlapOwner whose ownershipRole is integration or repair"
                        )


def validate_pipeline_plan(frontmatter: dict, stages_by_id=None, todos=None, workflow_source: bool = False) -> None:
    if not frontmatter.get("_pipeline_present"):
        return

    pipeline = frontmatter.get("pipeline", {})
    stages = pipeline.get("stages", [])
    if not stages:
        fail("pipeline.stages: must define at least one stage")

    execution = as_text(frontmatter.get("execution", ""))
    if stages_by_id is None:
        stages_by_id = resolve_stage_map(stages, execution, workflow_source=workflow_source)
    else:
        for ordinal, stage in enumerate(stages, start=1):
            validate_stage(stage, ordinal, execution, workflow_source=workflow_source)

    validate_parallel_stages(pipeline, stages_by_id)

    validate_planner_plan_from_graph(stages_by_id)
    validate_approval_graph(stages_by_id, todos if todos is not None else frontmatter.get("todos", []))

    profiles = pipeline.get("verificationProfiles", []) or []
    profile_names: set[str] = set()
    for profile_idx, profile in enumerate(profiles, start=1):
        name = as_text(profile.get("name", ""))
        if not name:
            fail(f"pipeline.verificationProfiles[{profile_idx}].name: required")
        if name in profile_names:
            fail(f"pipeline.verificationProfiles: duplicate profile name {name!r}")
        profile_names.add(name)
        steps = profile.get("steps", [])
        if not isinstance(steps, list) or not steps:
            fail(f"pipeline.verificationProfiles[{name}].steps: must be a non-empty array")
        for step_idx, step in enumerate(steps, start=1):
            step_name = as_text(step.get("name", ""))
            command = as_text(step.get("command", ""))
            timeout = step.get("timeout", 300)
            if not step_name or not command:
                fail(f"pipeline.verificationProfiles[{name}].steps[{step_idx}]: name and command are required")
            if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
                fail(f"pipeline.verificationProfiles[{name}].steps[{step_idx}].timeout: must be a positive integer")

    for stage_id, stage in stages_by_id.items():
        owner = as_text(stage.get("overlapOwner", ""))
        if owner and owner not in stages_by_id:
            fail(f"stage {stage_id} overlapOwner: unknown stage {owner!r}")
        if as_text(stage.get("type", "")) == "gate":
            profile = as_text(stage.get("profile", ""))
            if profile and profile not in profile_names:
                fail(f"stage {stage_id} profile: unknown verification profile {profile!r}")

    tooling = pipeline.get("tooling")
    if tooling:
        if pipeline.get("ralphMode"):
            fail(
                "pipeline: cannot declare both ralphMode and tooling -- "
                "choose either pipeline.ralphMode or pipeline.tooling, not both"
            )
        default_profile = as_text(tooling.get("defaultProfile", ""))
        if not default_profile:
            fail("pipeline.tooling.defaultProfile: required when pipeline.tooling is present")
        if default_profile not in TOOLING_PROFILE_NAMES:
            fail(
                "pipeline.tooling.defaultProfile: invalid profile "
                f"{default_profile!r} (expected one of: {', '.join(sorted(TOOLING_PROFILE_NAMES))})"
            )
        overrides = tooling.get("overrides", {}) or {}
        for override_stage_id, override_profile in overrides.items():
            if override_stage_id not in stages_by_id:
                fail(f"pipeline.tooling.overrides: unknown stage {override_stage_id!r}")
            if as_text(stages_by_id[override_stage_id].get("type", "")) == "approval":
                fail(
                    f"pipeline.tooling.overrides: approval stage {override_stage_id!r} "
                    "cannot take a tooling profile"
                )
            if override_profile not in TOOLING_PROFILE_NAMES:
                fail(
                    f"pipeline.tooling.overrides[{override_stage_id}]: invalid profile "
                    f"{override_profile!r} (expected one of: {', '.join(sorted(TOOLING_PROFILE_NAMES))})"
                )
        for resolved_stage_id, resolved_stage in stages_by_id.items():
            if as_text(resolved_stage.get("type", "")) == "approval":
                continue
            resolved_stage["toolingProfile"] = overrides.get(resolved_stage_id, default_profile)

    repair_rounds = pipeline.get("repairRounds") or {}
    if repair_rounds:
        for phase_name in ("integrate", "gate", "reintegrate"):
            phase = repair_rounds.get(phase_name) or {}
            if phase:
                validate_instructions_allowed(
                    phase,
                    f"repairRounds.{phase_name}",
                    False,
                    f"repairRounds.{phase_name} nodes",
                )
        diagnose = repair_rounds.get("diagnose") or {}
        if diagnose:
            validate_instructions_allowed(
                diagnose, "repairRounds.diagnose", True, "repair diagnose/lanes"
            )
        for lane_idx, lane in enumerate(repair_rounds.get("lanes") or [], start=1):
            lane_id = as_text((lane or {}).get("id", "")) or str(lane_idx)
            validate_instructions_allowed(
                lane or {},
                f"repairRounds lane {lane_id!r}",
                True,
                "repair diagnose/lanes",
            )
    for phase_name in ("gate",):
        phase = repair_rounds.get(phase_name) or {}
        if phase:
            profile = as_text(phase.get("profile", ""))
            if profile and profile not in profile_names:
                fail(f"repairRounds.{phase_name}.profile: unknown verification profile {profile!r}")

    if todos is None:
        todos = frontmatter.get("todos", [])

    if todos is not None:
        plan_runtime = validate_plan_header_routing(frontmatter)
        plan_session = as_text(frontmatter.get("sessionStrategy", ""))
        for ordinal, todo in enumerate(todos, start=1):
            validate_todo(
                todo, ordinal, stages_by_id,
                plan_runtime=plan_runtime, plan_session=plan_session,
            )

    stage_effective_produces = {
        as_text(stage.get("id", "")): normalize_artifacts(stage.get("produces", []))
        for stage in stages
    }
    stage_raw_produces = {
        as_text(stage.get("id", "")): raw_artifacts(stage.get("produces", []))
        for stage in stages
    }
    for todo in todos or []:
        stage_id = as_text(todo.get("stage", ""))
        if stage_id:
            stage_effective_produces[stage_id] = normalize_artifacts(
                stage_effective_produces.get(stage_id, []) + todo.get("produces", [])
            )
            stage_raw_produces[stage_id] = stage_raw_produces.get(stage_id, []) + raw_artifacts(
                todo.get("produces", [])
            )

    plan_execution = as_text(frontmatter.get("execution", ""))
    pipeline_max_rework_iterations = pipeline.get("maxReworkIterations", "")
    reserved_rework_ids = set(stages_by_id.keys())
    for ordinal, stage in enumerate(stages, start=1):
        validate_loop_rules(
            stage,
            ordinal,
            stages_by_id,
            stage_effective_produces,
            stage_raw_produces,
            plan_execution,
            pipeline_max_rework_iterations,
            stages,
            reserved_rework_ids,
            workflow_source=workflow_source,
        )

    if frontmatter.get("execution") == "graph":
        validate_write_scope_conflicts(stages)

    frontmatter["_graph_artifact_producers"], frontmatter["_graph_external_preconditions"] = build_graph_artifact_maps(
        stages, todos or []
    )


def first_non_empty(*values: str) -> str:
    for value in values:
        if as_text(value):
            return as_text(value)
    return ""


def build_raw_metadata(todo: dict) -> dict:
    return {
        "todoId": as_text(todo.get("id", "")),
        "ordinal": todo.get("ordinal", 0),
        "stage": as_text(todo.get("stage", "")),
        "runtime": as_text(todo.get("runtime", "")),
        "model": as_text(todo.get("model", "")),
        "sessionStrategy": as_text(todo.get("sessionStrategy", "")),
        "contextBudget": as_text(todo.get("contextBudget", "")),
        "nativeSubagents": as_text(todo.get("nativeSubagents", "")),
        "requires": raw_artifacts(todo.get("requires", [])),
        "produces": raw_artifacts(todo.get("produces", [])),
        "content": as_text(todo.get("content", "")),
        "verification": as_text(todo.get("verification", "")),
        "status": as_text(todo.get("status", "")),
    }


def build_effective_metadata(todo: dict, stage: dict, plan_runtime: str = "") -> dict:
    requires = normalize_artifacts((stage or {}).get("requires", []) + todo.get("requires", []))
    produces = normalize_artifacts((stage or {}).get("produces", []) + todo.get("produces", []))
    runtime = first_non_empty(
        todo.get("runtime", ""),
        (stage or {}).get("runtime", ""),
        plan_runtime,
    )
    agent = first_non_empty(todo.get("agent", ""), (stage or {}).get("agent", ""))
    todo_runtime = as_text(todo.get("runtime", ""))
    baseline_runtime = first_non_empty((stage or {}).get("runtime", ""), plan_runtime)
    if todo_runtime and baseline_runtime and todo_runtime != baseline_runtime \
            and not as_text(todo.get("model", "")):
        # Runtime-only switch: the baseline model belongs to the baseline
        # runtime and must not carry across; the switched runtime resolves its
        # own saved/native default downstream.
        model = ""
    else:
        model = first_non_empty(todo.get("model", ""), (stage or {}).get("model", ""))
    session_strategy = first_non_empty(todo.get("sessionStrategy", ""), (stage or {}).get("sessionStrategy", ""))
    context_budget = first_non_empty(todo.get("contextBudget", ""), (stage or {}).get("contextBudget", ""))
    # Standard (unstaged) TODOs resolve nativeSubagents with default inherit.
    # Graph/orchestration staged paths resolve nativeSubagents with default off.
    # Bridge the resolved value into subagents so existing routing/env wiring
    # keeps working until callers read nativeSubagents exclusively.
    if not as_text(todo.get("stage", "")) and not stage:
        native_subagents = first_non_empty(todo.get("nativeSubagents", "")) or "inherit"
        subagents = native_subagents
    else:
        native_subagents = first_non_empty(
            todo.get("nativeSubagents", ""),
            (stage or {}).get("nativeSubagents", ""),
        ) or staged_native_subagents_default(runtime)
        subagents = native_subagents
    plan_file = as_text((stage or {}).get("planFile", ""))
    if runtime and runtime not in ALLOWED_RUNTIMES:
        fail(f"todo {todo.get('id', '') or todo.get('ordinal', '')} invalid effective runtime {runtime!r}")
    return {
        "todoId": as_text(todo.get("id", "")),
        "ordinal": todo.get("ordinal", 0),
        "stage": as_text(todo.get("stage", "")),
        "runtime": runtime,
        "model": model,
        "sessionStrategy": session_strategy,
        "contextBudget": context_budget,
        "nativeSubagents": native_subagents,
        "requires": requires,
        "produces": produces,
        "loopBackTo": as_text((stage or {}).get("loopBackTo", "")),
        "maxIterations": (stage or {}).get("maxIterations", ""),
        "loopCheck": normalize_loop_check((stage or {}).get("loopCheck", {})),
        "onExhausted": as_text((stage or {}).get("onExhausted", "")),
        "planFile": plan_file,
    }


def build_approval_orch_stage(stage: dict) -> dict:
    """Compile public type: approval to an explicit internal approval stage marker.

    Emits type=approval with question/changesTarget/dependsOn/inputArtifacts only.
    Never maps to checkpoint or humanAck, and never depends on ORCHESTRATOR_HUMAN_ACK.
    """
    out = {
        "id": as_text(stage.get("id", "")),
        "type": "approval",
        "question": as_text(stage.get("question", "")),
        "changesTarget": as_text(stage.get("changesTarget", "")),
    }
    depends_on = stage.get("dependsOn")
    if isinstance(depends_on, list) and depends_on:
        out["dependsOn"] = [
            _parse_dep_entry(item)[0] for item in depends_on if _parse_dep_entry(item)[0]
        ]
    requires = raw_artifacts(stage.get("requires", []))
    if requires:
        out["inputArtifacts"] = [
            {key: value for key, value in item.items() if key in {"path", "schema", "required"}}
            for item in requires
        ]
    return out


def build_orch_stage(stage: dict, stage_todos: list) -> dict:
    """Map a pipeline stage (+ its inline todos) to the .orch.json stage shape
    that orchestrator.sh consumes. A stage either delegates to a planFile (-> plan)
    or carries inline todos (-> _inlineTodos for the caller to materialize)."""
    if as_text(stage.get("type", "")) == "approval":
        return build_approval_orch_stage(stage)
    out = {"id": as_text(stage.get("id", ""))}
    for key in ("runtime", "model", "sessionStrategy", "contextBudget", "agentGitAccess", "parallelMutation", "profile", "overlapOwner", "ownershipRole", "toolingProfile", "instructions"):
        value = as_text(stage.get(key, ""))
        if value:
            out[key] = value
    # Agent stages and consensus voters compile nativeSubagents (agent stages
    # default to off only on a runtime with a proven deny boundary; voters are
    # force-set to off before this helper runs).
    native_subagents = as_text(stage.get("nativeSubagents", ""))
    stage_type_for_ns = as_text(stage.get("type", ""))
    if native_subagents:
        out["nativeSubagents"] = native_subagents
    elif stage_type_for_ns in {"", "agent", "stage"}:
        out["nativeSubagents"] = staged_native_subagents_default(as_text(stage.get("runtime", "")))
    # Keep legacy .orch.json characterization byte-identical: delegation is
    # graph-only policy metadata, not an orchestrator v1 surface.
    # Never emit removed role; agent remains only for non-role legacy paths that
    # still carry an agent string after validation.
    agent = as_text(stage.get("agent", ""))
    if agent:
        out["agent"] = agent
    if as_text(stage.get("workspaceMode", "")):
        out["workspaceMode"] = as_text(stage.get("workspaceMode", ""))
        if as_text(stage.get("workspaceMode", "")) == "worktree" and "agentGitAccess" not in out:
            out["agentGitAccess"] = "off"
    if as_text(stage.get("setupProfile", "")):
        out["setupProfile"] = as_text(stage.get("setupProfile", ""))
    write_scopes = stage.get("writeScopes", [])
    if isinstance(write_scopes, list) and write_scopes:
        out["writeScopes"] = [as_text(item) for item in write_scopes if as_text(item)]
    if stage.get("acknowledgeSharedMutationRisk") is True:
        out["acknowledgeSharedMutationRisk"] = True
    for key in ("type", "policy", "onVoterError", "verdictSchema"):
        value = as_text(stage.get(key, ""))
        if value:
            out[key] = value
    for key in ("quorum", "minRuntimes"):
        value = stage.get(key, "")
        if value != "":
            out[key] = value
    voters = stage.get("voters", [])
    if isinstance(voters, list) and voters:
        out["voters"] = [
            {
                key: value
                for key, value in {
                    "id": as_text(voter.get("id", "")),
                    "runtime": as_text(voter.get("runtime", "")),
                    "model": as_text(voter.get("model", "")),
                    "sessionStrategy": as_text(voter.get("sessionStrategy", "")),
                    "contextBudget": as_text(voter.get("contextBudget", "")),
                    "nativeSubagents": as_text(voter.get("nativeSubagents", "")),
                    "instructions": as_text(voter.get("instructions", "")),
                }.items()
                if value
            }
            for voter in voters
        ]
    depends_on = stage.get("dependsOn")
    if isinstance(depends_on, list) and depends_on:
        out["dependsOn"] = [_parse_dep_entry(item)[0] for item in depends_on if _parse_dep_entry(item)[0]]
    if stage.get("grader") is True:
        out["grader"] = True
        rubric = as_text(stage.get("rubric", ""))
        if rubric:
            out["rubric"] = rubric
    router = stage.get("router")
    if isinstance(router, dict) and router:
        out_router = {}
        allowed = [as_text(item) for item in router.get("allowedTargets", []) if as_text(item)]
        if allowed:
            out_router["allowedTargets"] = allowed
        terminal = [as_text(item) for item in router.get("terminalOutcomes", []) if as_text(item)]
        if terminal:
            out_router["terminalOutcomes"] = terminal
        default_target = as_text(router.get("defaultTarget", ""))
        if default_target:
            out_router["defaultTarget"] = default_target
        on_invalid = as_text(router.get("onInvalid", ""))
        if on_invalid:
            out_router["onInvalid"] = on_invalid
        if out_router:
            out["router"] = out_router
    # Artifact contracts, handoffs, schemas, and loop/evaluator metadata come
    # only from this stage's declarations. Never merge profile
    # output_artifacts, verdicts, provenance, or loop conditions.
    produces = raw_artifacts(stage.get("produces", []))
    if produces:
        out["outputArtifacts"] = produces
        out["artifacts"] = produces
    requires = raw_artifacts(stage.get("requires", []))
    if requires:
        out["inputArtifacts"] = [
            {key: value for key, value in item.items() if key in {"path", "schema", "required"}}
            for item in requires
        ]
    loop_back = as_text(stage.get("loopBackTo", ""))
    if loop_back:
        loop_control = {"loopBackTo": loop_back}
        max_iterations = stage.get("maxIterations", "")
        if isinstance(max_iterations, int):
            loop_control["maxIterations"] = max_iterations
        loop_check = normalize_loop_check(stage.get("loopCheck", {}))
        if loop_check.get("schema"):
            loop_control["evaluatorSchema"] = loop_check["schema"]
        on_exhausted = as_text(stage.get("onExhausted", ""))
        if on_exhausted:
            loop_control["onExhausted"] = on_exhausted
        out["loopControl"] = loop_control
    plan_file = as_text(stage.get("planFile", ""))
    if plan_file:
        out["plan"] = plan_file
    else:
        out["_inlineTodos"] = [
            {
                "id": as_text(todo.get("id", "")),
                "content": as_text(todo.get("content", "")),
                "verification": as_text(todo.get("verification", "")),
                "status": as_text(todo.get("status", "")) or "pending",
            }
            for todo in stage_todos
        ]
    planner = stage.get("planner")
    if isinstance(planner, dict) and planner:
        # Compile authored planner config unchanged; do not resolve or materialize.
        out["planner"] = {
            key: planner[key]
            for key in ("outputMode", "maxTodos")
            if key in planner
        }
    plan_from = as_text(stage.get("planFrom", ""))
    if plan_from:
        out["planFrom"] = plan_from
    for key in ("maxParallel", "edgeDerivation", "failurePolicy", "publishMode"):
        value = stage.get(key)
        if value not in (None, ""):
            out[key] = value
    return out


def get_ralph_version() -> str:
    import os
    from pathlib import Path
    import subprocess

    env_version = os.environ.get("RALPH_VERSION", "").strip()
    if env_version:
        return env_version

    repo_root = Path(os.getcwd()).resolve()
    for candidate in (
        repo_root / "bundle" / ".ralph" / "VERSION",
        repo_root / "bundle" / ".ralph" / "version",
        repo_root / "VERSION",
    ):
        if candidate.is_file():
            value = candidate.read_text(encoding="utf-8").strip()
            if value:
                return value

    try:
        value = subprocess.check_output(
            ["git", "-C", str(repo_root), "describe", "--tags", "--always", "--dirty"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if value:
            return value
    except Exception:
        pass

    return "1.0.0"


def _resolve_artifact_namespace(declared: str, base: str) -> str:
    """Namespace for artifacts and {{ARTIFACT_NS}}.

    Normally the plan's declared namespace, else its filename. A workflow run's
    materialized input is always input.plan.md, so that gave every run in a
    project the same namespace: artifacts overwrote each other across runs, and
    because a stage's required inputs are gated on bare file existence, a later
    run could satisfy its requires: on an earlier run's artifact and build on
    stale evidence.

    RALPH_ARTIFACT_NS_OVERRIDE lets the workflow layer -- which is the only
    layer that knows the workflow id and the run token -- supply the whole
    namespace. The compiler stays policy-free.
    """
    import os as _os

    override = _os.environ.get("RALPH_ARTIFACT_NS_OVERRIDE", "").strip()
    if override:
        return sanitize_namespace(override)
    return declared or sanitize_namespace(base)


def sanitize_namespace(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", value)


# --- workflow instantiation (workflow + task -> materialized plan) ----------
#
# Instantiation happens once, before any engine compilation. The materialized
# plan is an ordinary plan file: by the time the graph/orchestration compiler
# runs there is no {{TASK}} token left anywhere, and nothing downstream has to
# know a workflow was involved. Task text is treated as opaque data end to end:
# it arrives as an argv value, is copied into the parsed structure verbatim, and
# is written out as block-scalar content. It is never interpolated into a shell
# command, a format string, or eval.

WORKFLOW_TASK_PLACEHOLDER = "{{TASK}}"

# Keys the parser adds for its own bookkeeping; they are not authored fields and
# must not be serialized back out. Public mode/engine/defaults/planInput belong
# only on workflow sources; materialized plans emit internal execution instead
# and strip planInput only after run materialization records binding.
SERIALIZE_SKIP_KEYS = {"ordinal", "kind", "engine", "mode", "defaults", "planInput"}

PLAIN_SCALAR_RE = re.compile(r"^[A-Za-z0-9_./][^\n]*$")


def substitute_task(content: str, task: str) -> str:
    """Replace every {{TASK}} in content, indenting continuation lines.

    A multiline task placed at a nonzero indent must keep that indent on every
    line, otherwise the emitted block scalar would change shape. When the
    placeholder sits at the start of its line (the normal authoring shape) the
    task is inserted byte for byte.
    """
    if WORKFLOW_TASK_PLACEHOLDER not in content:
        return content
    out_lines = []
    for line in content.split("\n"):
        if WORKFLOW_TASK_PLACEHOLDER not in line:
            out_lines.append(line)
            continue
        indent = line[: len(line) - len(line.lstrip(" \t"))]
        replacement = task.replace("\n", "\n" + indent) if indent else task
        out_lines.extend(line.replace(WORKFLOW_TASK_PLACEHOLDER, replacement).split("\n"))
    return "\n".join(out_lines)


WORKFLOW_INPUT_PLAN_PLACEHOLDER = "{{INPUT_PLAN}}"


def substitute_input_plan(content: str, input_plan: str) -> str:
    """Replace every {{INPUT_PLAN}} with the imported immutable source path.

    Plan-entry materialization resolves this token so the emitted plan is a
    concrete non-workflow plan: nothing downstream has to know about it.
    """
    if not input_plan or WORKFLOW_INPUT_PLAN_PLACEHOLDER not in content:
        return content
    return content.replace(WORKFLOW_INPUT_PLAN_PLACEHOLDER, input_plan)


def instantiate_todos(todos: list, task: str, input_plan: str = "") -> list:
    """Deep-copy the parsed todos with {{TASK}} resolved in content only.

    On the plan-entry path {{INPUT_PLAN}} is resolved in content and
    verification, so no workflow-only token survives into the emitted plan.
    """
    materialized = []
    for todo in todos:
        clone = copy.deepcopy(todo)
        if isinstance(clone.get("content"), str):
            clone["content"] = substitute_task(clone["content"], task)
            clone["content"] = substitute_input_plan(clone["content"], input_plan)
        if input_plan and isinstance(clone.get("verification"), str):
            clone["verification"] = substitute_input_plan(clone["verification"], input_plan)
        materialized.append(clone)
    return materialized


def is_plain_scalar(value: str) -> bool:
    """True when value can be emitted as an unquoted single-line scalar."""
    if not value or "\n" in value or value != value.strip():
        return False
    if not PLAIN_SCALAR_RE.match(value):
        return False
    return "#" not in value


def emit_block_scalar(key: str, value: str, indent: int, out: list, source: str) -> None:
    pad = " " * indent
    body_pad = " " * (indent + 2)
    lines = value.split("\n")
    significant = [line for line in lines if line.strip()]
    if significant:
        first_indent = len(significant[0]) - len(significant[0].lstrip(" "))
        min_indent = min(len(line) - len(line.lstrip(" ")) for line in significant)
        if first_indent > min_indent:
            fail(
                f"{source}: cannot serialize {key!r} as a block scalar because its first "
                "line is indented deeper than a later line"
            )
    out.append(f"{pad}{key}: |")
    for line in lines:
        out.append(f"{body_pad}{line}" if line.strip() else "")


def emit_field(key: str, value, indent: int, out: list, source: str) -> None:
    pad = " " * indent
    if value is None:
        return
    if isinstance(value, bool):
        out.append(f"{pad}{key}: {'true' if value else 'false'}")
        return
    if isinstance(value, int):
        out.append(f"{pad}{key}: {value}")
        return
    if isinstance(value, str):
        if is_plain_scalar(value):
            out.append(f"{pad}{key}: {value}")
        else:
            emit_block_scalar(key, value, indent, out, source)
        return
    if isinstance(value, list):
        if not value:
            out.append(f"{pad}{key}: []")
            return
        out.append(f"{pad}{key}:")
        for entry in value:
            emit_list_entry(entry, indent + 2, out, source)
        return
    if isinstance(value, dict):
        if not value:
            out.append(f"{pad}{key}: {{}}")
            return
        out.append(f"{pad}{key}:")
        emit_mapping(value, indent + 2, out, source)
        return
    fail(f"{source}: cannot serialize field {key!r} of type {type(value).__name__}")


def emit_list_entry(entry, indent: int, out: list, source: str) -> None:
    pad = " " * indent
    if isinstance(entry, str):
        out.append(f"{pad}- {entry}")
        return
    if isinstance(entry, list):
        out.append(f"{pad}- [{', '.join(str(item) for item in entry)}]")
        return
    if isinstance(entry, dict):
        shorthand = entry.get("__shorthand")
        if shorthand is not None:
            out.append(f"{pad}- {shorthand}")
            return
        nested: list = []
        emit_mapping(entry, indent + 2, out=nested, source=source)
        if not nested:
            out.append(f"{pad}- {{}}")
            return
        nested[0] = f"{pad}- {nested[0][indent + 2:]}"
        out.extend(nested)
        return
    fail(f"{source}: cannot serialize list entry of type {type(entry).__name__}")


def emit_mapping(mapping: dict, indent: int, out: list, source: str) -> None:
    shorthand_keys = {
        key[2:-len("_shorthand")]
        for key in mapping
        if key.startswith("__") and key.endswith("_shorthand")
    }
    for key, value in mapping.items():
        if key in SERIALIZE_SKIP_KEYS:
            continue
        if key.startswith("__") and key.endswith("_shorthand"):
            out.append(f"{' ' * indent}{key[2:-len('_shorthand')]}: {value}")
            continue
        if key in shorthand_keys:
            continue
        if key.startswith("_"):
            continue
        emit_field(key, value, indent, out, source)


def serialize_materialized_plan(frontmatter: dict, todos: list, engine: str, source: str) -> str:
    """Render a normal materialized plan: no kind/mode/engine, execution from engine."""
    out: list = ["---"]
    for key in ("name", "overview", "namespace"):
        value = as_text(frontmatter.get(key, ""))
        if value:
            emit_field(key, value, 0, out, source)
    if frontmatter.get("isProject"):
        emit_field("isProject", True, 0, out, source)
    emit_field("execution", engine, 0, out, source)
    instructions = as_text(frontmatter.get("instructions", ""))
    if instructions:
        emit_field("instructions", instructions, 0, out, source)
    if frontmatter.get("_pipeline_present"):
        emit_field("pipeline", frontmatter.get("pipeline", {}), 0, out, source)
    emit_field("todos", todos, 0, out, source)
    out.append("---")
    out.append("")
    return "\n".join(out) + "\n"


def write_plan_exclusively(output_path: str, text: str, source: str) -> None:
    """Write text to output_path atomically, refusing to clobber an existing file."""
    if os.path.exists(output_path):
        fail(f"{source}: refusing to overwrite existing output plan {output_path}")
    directory = os.path.dirname(os.path.abspath(output_path)) or "."
    if not os.path.isdir(directory):
        fail(f"{source}: output directory does not exist: {directory}")
    tmp_fd, tmp_path = tempfile.mkstemp(prefix=".workflow-instantiate.", dir=directory)
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(tmp_path, output_path)
        except OSError:
            fail(f"{source}: refusing to overwrite existing output plan {output_path}")
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


WORKFLOW_INCLUDE_RE = re.compile(r"\{\{INCLUDE:([A-Za-z0-9][A-Za-z0-9-]*)\}\}")


def expand_workflow_includes(text: str, source: str) -> str:
    """Replace {{INCLUDE:<name>}} with a bundled instruction fragment.

    Shared stage guidance (scope discipline, the evaluator contract, planning
    budgets) applies to many stages across many workflows. Restating it inline
    in every workflow is how the copies drift apart. Expansion happens on the
    raw source before parsing, so every validator and consumer downstream sees
    ordinary instruction text and needs no knowledge of the token.

    Fragment names resolve only inside the bundled _fragments directory: the
    name is a bare slug, never a path, so a workflow cannot pull in an
    arbitrary file.
    """
    if "{{INCLUDE:" not in text:
        return text
    fragments_dir = os.environ.get("RALPH_WORKFLOW_FRAGMENTS_DIR", "").strip()
    if not fragments_dir or not os.path.isdir(fragments_dir):
        fail(f"{source}: {{{{INCLUDE:...}}}} used but the workflow fragments directory is unavailable")

    cache: dict[str, str] = {}

    def _load(name: str) -> str:
        if name in cache:
            return cache[name]
        candidate = os.path.join(fragments_dir, f"{name}.md")
        if os.path.realpath(os.path.dirname(candidate)) != os.path.realpath(fragments_dir):
            fail(f"{source}: unknown instruction fragment {name!r}")
        if not os.path.isfile(candidate):
            fail(f"{source}: unknown instruction fragment {name!r} (expected {candidate})")
        with open(candidate, encoding="utf-8") as handle:
            body = handle.read().strip("\n")
        if "{{INCLUDE:" in body:
            fail(f"{source}: instruction fragment {name!r} may not include another fragment")
        cache[name] = body
        return body

    out_lines = []
    for line in text.split("\n"):
        match = WORKFLOW_INCLUDE_RE.search(line)
        if match is None:
            out_lines.append(line)
            continue
        indent = line[: len(line) - len(line.lstrip(" \t"))]

        def _replace(m, _indent=indent):
            body = _load(m.group(1))
            return body.replace("\n", "\n" + _indent) if _indent else body

        out_lines.extend(WORKFLOW_INCLUDE_RE.sub(_replace, line).split("\n"))
    expanded = "\n".join(out_lines)
    if "{{INCLUDE:" in expanded:
        fail(f"{source}: unresolved {{{{INCLUDE:...}}}} token after fragment expansion")
    return expanded


with open(plan_path, encoding="utf-8") as fh:
    all_lines = expand_workflow_includes(fh.read(), plan_path).splitlines()

if not all_lines or all_lines[0].strip() != "---":
    fail("pipeline metadata helpers require YAML frontmatter")

closing = None
for idx in range(1, len(all_lines)):
    # The frontmatter delimiter lives at column 0. Matching an indented "---"
    # here would truncate frontmatter that legitimately contains a "---" line
    # inside a block scalar, which the rest of the toolchain already tolerates.
    if all_lines[idx].rstrip() == "---":
        closing = idx
        break

if closing is None:
    fail("pipeline metadata helpers require a closing frontmatter delimiter")

frontmatter = parse_frontmatter(all_lines[1:closing])
stages = frontmatter["pipeline"].get("stages", [])
todos = frontmatter.get("todos", [])
for ordinal, todo in enumerate(todos, start=1):
    todo["ordinal"] = ordinal

WORKFLOW_SOURCE_MODES = {
    "workflow-validate",
    "workflow-instantiate",
    "workflow-instantiate-provided",
}
workflow_source = mode in WORKFLOW_SOURCE_MODES

if workflow_source:
    if as_text(frontmatter.get("kind", "")) != "workflow":
        fail("workflow files require 'kind: workflow' in frontmatter")
    if not as_text(frontmatter.get("mode", "")):
        fail("workflow files require 'mode: sequential' or 'mode: dependency'")
elif as_text(frontmatter.get("kind", "")) == "workflow":
    fail(
        "workflow source is not a runnable plan: instantiate it with a task "
        "before graph/orchestration compilation"
    )

validate_top_level_defaults(frontmatter, workflow_source)

stages_by_id = resolve_stage_map(
    stages, as_text(frontmatter.get("execution", "")), workflow_source=workflow_source
)
plan_runtime = validate_plan_header_routing(frontmatter)
plan_session = as_text(frontmatter.get("sessionStrategy", ""))
for todo in todos:
    validate_todo(
        todo, todo["ordinal"], stages_by_id,
        plan_runtime=plan_runtime, plan_session=plan_session,
    )

if frontmatter.get("_pipeline_present"):
    validate_pipeline_plan(frontmatter, stages_by_id, todos, workflow_source=workflow_source)

validate_top_level_plan_input(frontmatter, stages_by_id, todos, workflow_source)
validate_input_plan_token_usage(
    frontmatter, stages, todos, workflow_source, mode
)

if workflow_source:
    plan_input = frontmatter.get("planInput") if frontmatter.get("_plan_input_present") else None
    validate_workflow_todo_tokens(todos, plan_input=plan_input)

if mode == "workflow-validate":
    raise SystemExit(0)

if mode in ("workflow-instantiate", "workflow-instantiate-provided"):
    if len(extra_args) < 2:
        fail(f"{mode} requires a task text and an output plan path")
    task_text = extra_args[0]
    output_plan_path = extra_args[1]
    instantiate_opts = {
        "fallback_runtime": "",
        "fallback_model": "",
        "provided_plan_runtime": "",
        "provided_plan_model": "",
        "provided_plan_path": "",
        "metadata_out": "",
    }
    stage_overrides: dict = {}
    for raw_opt in extra_args[2:]:
        if "=" not in raw_opt:
            fail(
                f"{plan_path}: unknown workflow-instantiate argument {raw_opt!r}; "
                "expected key=value"
            )
        opt_key, opt_val = raw_opt.split("=", 1)
        # Per-stage routing overrides: stage_runtime.<stage-id>=<runtime> and
        # stage_model.<stage-id>=<model>. These carry an operator's per-stage
        # interactive selection for one run without editing the workflow source.
        if opt_key.startswith("stage_runtime.") or opt_key.startswith("stage_model."):
            opt_prefix, _, opt_stage = opt_key.partition(".")
            if not opt_stage:
                fail(f"{plan_path}: {opt_prefix} requires a stage id ({opt_prefix}.<stage-id>=...)")
            field = "runtime" if opt_prefix == "stage_runtime" else "model"
            stage_overrides.setdefault(opt_stage, {})[field] = opt_val
            continue
        if opt_key not in instantiate_opts:
            fail(
                f"{plan_path}: unknown {mode} key {opt_key!r}; "
                "expected fallback_runtime|fallback_model|provided_plan_runtime|"
                "provided_plan_model|provided_plan_path|metadata_out|"
                "stage_runtime.<stage-id>|stage_model.<stage-id>"
            )
        instantiate_opts[opt_key] = opt_val
    if not task_text.strip():
        fail(f"{plan_path}: instantiating a workflow requires a non-empty task")
    if not output_plan_path.strip():
        fail(f"{plan_path}: instantiating a workflow requires an output plan path")
    input_plan_path = instantiate_opts["provided_plan_path"]
    if mode == "workflow-instantiate-provided":
        if not input_plan_path.strip():
            fail(f"{plan_path}: {mode} requires provided_plan_path=<imported-source>")
        if not frontmatter.get("_plan_input_present"):
            fail(
                f"{plan_path}: workflow declares no planInput and cannot accept a "
                "supplied plan"
            )
    else:
        if input_plan_path:
            fail(
                f"{plan_path}: provided_plan_path requires the "
                "workflow-instantiate-provided mode"
            )
        if frontmatter.get("_plan_input_present") and bool(
            (frontmatter.get("planInput") or {}).get("required")
        ):
            fail(
                f"{plan_path}: required planInput rejects task-only start; "
                "supply a leaf plan with --plan"
            )
    engine_value = as_text(frontmatter.get("execution", ""))
    if engine_value not in WORKFLOW_ENGINES:
        fail(f"{plan_path}: workflow mode must map to execution 'graph' or 'orchestration'")

    # Load pure materialize helpers (stdlib-tested in wizard-workflow-template).
    import importlib.util
    from pathlib import Path as _Path

    _wft_path = (
        _Path(graph_authoring_contract_path).resolve().parent.parent
        / "python"
        / "wizard-workflow-template.py"
    )
    _wft_spec = importlib.util.spec_from_file_location(
        "wizard_workflow_template_materialize", _wft_path
    )
    if _wft_spec is None or _wft_spec.loader is None:
        fail(f"{plan_path}: cannot load workflow materialize helpers from {_wft_path}")
    _wft = importlib.util.module_from_spec(_wft_spec)
    _wft_spec.loader.exec_module(_wft)

    # Record run-entry metadata BEFORE stripping workflow-only fields.
    run_entry_meta = _wft.capture_run_entry_metadata(frontmatter)
    defaults_block = frontmatter.get("defaults") if isinstance(frontmatter.get("defaults"), dict) else {}
    workflow_runtime = as_text(defaults_block.get("runtime", ""))
    workflow_model = as_text(defaults_block.get("model", ""))
    plan_input_stage = ""
    if frontmatter.get("_plan_input_present"):
        plan_input_stage = as_text((frontmatter.get("planInput") or {}).get("stage", ""))

    source_stages = list(frontmatter.get("pipeline", {}).get("stages", []) or [])
    try:
        routed_stages = _wft.apply_materialized_stage_routing(
            source_stages,
            fallback_runtime=instantiate_opts["fallback_runtime"],
            fallback_model=instantiate_opts["fallback_model"],
            workflow_runtime=workflow_runtime,
            workflow_model=workflow_model,
            provided_plan_runtime=instantiate_opts["provided_plan_runtime"],
            provided_plan_model=instantiate_opts["provided_plan_model"],
            plan_input_stage=plan_input_stage,
            stage_overrides=stage_overrides,
        )
    except _wft.WorkflowMaterializeError as exc:
        fail(f"{plan_path}: {exc}")

    # Task substitution only on TODO content. Never inject runtime/model into TODOs.
    materialized_todos = instantiate_todos(todos, task_text, input_plan_path)
    try:
        _wft.assert_todos_routing_untouched(todos, materialized_todos)
    except _wft.WorkflowMaterializeError as exc:
        fail(f"{plan_path}: {exc}")
    for materialized in materialized_todos:
        if WORKFLOW_TASK_PLACEHOLDER in as_text(materialized.get("content", "")):
            fail(f"{plan_path}: task substitution left an unresolved {{{{TASK}}}} token")
    for src_todo, out_todo in zip(todos, materialized_todos):
        if as_text(out_todo.get("runtime", "")) != as_text(src_todo.get("runtime", "")):
            fail(f"{plan_path}: workflow materialization must not write runtime into TODOs")
        if as_text(out_todo.get("model", "")) != as_text(src_todo.get("model", "")):
            fail(f"{plan_path}: workflow materialization must not write model into TODOs")

    # Strip workflow-only defaults/mode/kind/planInput only after metadata capture.
    if input_plan_path:
        # Resolve {{INPUT_PLAN}} everywhere the validator allows it, so the
        # emitted plan carries no workflow-only token.
        for stage in routed_stages:
            if isinstance(stage.get("instructions"), str):
                stage["instructions"] = substitute_input_plan(
                    stage["instructions"], input_plan_path
                )
            for field_name in ("requires", "produces"):
                for item in stage.get(field_name, []) or []:
                    if isinstance(item, dict) and isinstance(item.get("path"), str):
                        item["path"] = substitute_input_plan(item["path"], input_plan_path)
            for voter in stage.get("voters", []) or []:
                if isinstance(voter, dict) and isinstance(voter.get("instructions"), str):
                    voter["instructions"] = substitute_input_plan(
                        voter["instructions"], input_plan_path
                    )

    materialize_fm = copy.deepcopy(frontmatter)
    materialize_fm["pipeline"] = copy.deepcopy(frontmatter.get("pipeline") or {})
    materialize_fm["pipeline"]["stages"] = routed_stages
    if input_plan_path and isinstance(materialize_fm.get("instructions"), str):
        materialize_fm["instructions"] = substitute_input_plan(
            materialize_fm["instructions"], input_plan_path
        )
    for skip_key in ("kind", "mode", "engine", "defaults", "planInput"):
        materialize_fm.pop(skip_key, None)
    materialize_fm.pop("_defaults_present", None)
    materialize_fm.pop("_plan_input_present", None)

    rendered = serialize_materialized_plan(
        materialize_fm, materialized_todos, engine_value, plan_path
    )

    # Validate concrete result when every ordinary executable stage has runtime.
    def _ordinary_unresolved(stage_list):
        pending = []
        for st in stage_list:
            st_type = as_text(st.get("type", ""))
            if st_type in SUPERVISOR_STAGE_TYPES or st_type == "consensus":
                continue
            if not as_text(st.get("runtime", "")):
                pending.append(as_text(st.get("id", "")))
        return pending

    unresolved_ids = _ordinary_unresolved(routed_stages)
    if not unresolved_ids:
        # Re-parse rendered plan as a non-workflow concrete plan.
        rendered_lines = rendered.splitlines()
        if not rendered_lines or rendered_lines[0].strip() != "---":
            fail(f"{plan_path}: materialized plan missing frontmatter")
        close_idx = None
        for ridx in range(1, len(rendered_lines)):
            if rendered_lines[ridx].rstrip() == "---":
                close_idx = ridx
                break
        if close_idx is None:
            fail(f"{plan_path}: materialized plan missing closing frontmatter")
        concrete_fm = parse_frontmatter(rendered_lines[1:close_idx])
        concrete_stages = concrete_fm.get("pipeline", {}).get("stages", []) or []
        concrete_todos = concrete_fm.get("todos", []) or []
        for ordinal, todo in enumerate(concrete_todos, start=1):
            todo["ordinal"] = ordinal
        concrete_map = resolve_stage_map(
            concrete_stages,
            as_text(concrete_fm.get("execution", "")),
            workflow_source=False,
        )
        concrete_plan_runtime = validate_plan_header_routing(concrete_fm)
        concrete_plan_session = as_text(concrete_fm.get("sessionStrategy", ""))
        for todo in concrete_todos:
            validate_todo(
                todo, todo["ordinal"], concrete_map,
                plan_runtime=concrete_plan_runtime,
                plan_session=concrete_plan_session,
            )
        if concrete_fm.get("_pipeline_present"):
            validate_pipeline_plan(
                concrete_fm, concrete_map, concrete_todos, workflow_source=False
            )

    if instantiate_opts["metadata_out"]:
        meta_path = instantiate_opts["metadata_out"]
        meta_dir = os.path.dirname(os.path.abspath(meta_path)) or "."
        if not os.path.isdir(meta_dir):
            fail(f"{plan_path}: metadata_out directory does not exist: {meta_dir}")
        with open(meta_path, "w", encoding="utf-8") as meta_fh:
            json.dump(run_entry_meta, meta_fh, separators=(",", ":"), ensure_ascii=False)
            meta_fh.write("\n")

    write_plan_exclusively(output_plan_path, rendered, plan_path)
    print(output_plan_path)
    raise SystemExit(0)

if mode == "validate":
    raise SystemExit(0)

if mode == "orch":
    if not frontmatter.get("_pipeline_present"):
        fail("orch mode requires a pipeline block")
    import os
    base = os.path.basename(plan_path)
    for suffix in (".plan.md", ".md"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    name = frontmatter.get("name", "") or base
    namespace = _resolve_artifact_namespace(frontmatter.get("namespace", ""), base)
    todos_by_stage: dict = {}
    for item in todos:
        todos_by_stage.setdefault(as_text(item.get("stage", "")), []).append(item)
    orch_stages = [
        build_orch_stage(stage, todos_by_stage.get(as_text(stage.get("id", "")), []))
        for stage in stages
    ]
    result = {"name": name, "namespace": namespace, "stages": orch_stages}
    graph_producers, graph_external_preconditions = build_graph_artifact_maps(stages, todos)
    if frontmatter.get("execution") == "graph":
        result["artifactProducers"] = graph_producers
        if graph_external_preconditions:
            result["externalPreconditions"] = graph_external_preconditions
            warn(
                "external preconditions: "
                + ", ".join(
                    f"{item['path']} (consumer {item['consumer']})" for item in graph_external_preconditions
                )
            )
        result["graphEdges"] = build_graph_edges(
            stages,
            todos,
            graph_producers,
            as_text(frontmatter["pipeline"].get("edgeDerivation", "both")) or "both",
            bool(frontmatter["pipeline"].get("strictEdges", False)),
        )
    for key in ("maxParallel", "edgeDerivation", "failurePolicy", "publishMode", "strictEdges", "ralphMode", "tooling"):
        value = frontmatter["pipeline"].get(key)
        if value not in (None, ""):
            result[key] = value
    waves = frontmatter["pipeline"].get("parallelStages", [])
    if waves:
        result["parallelStages"] = waves
    print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
    raise SystemExit(0)


def validate_optional_role_reject_agent(obj: dict, prefix: str) -> None:
    """Reject removed profile agent fields and stale role fields."""
    if "agent" in obj:
        fail(
            f"{prefix} agent: was removed. Use inline workflow instructions "
            f"(instructions: text)."
        )
    if "agentSource" in obj:
        fail(
            f"{prefix} agentSource: was removed. Use inline workflow instructions "
            f"(instructions: text)."
        )
    reject_stale_role(obj, prefix)


def validate_repair_agent_native_subagents(obj: dict, prefix: str) -> None:
    """Repair diagnose/lanes follow ordinary agent-stage nativeSubagents rules."""
    if "subagents" in obj:
        fail(
            f"{prefix} subagents: was removed. Use nativeSubagents: off|inherit. "
            f"Use current workflow fields (see DELEGATION.md)"
        )
    if "nativeSubagents" in obj:
        native_subagents = as_text(obj.get("nativeSubagents", ""))
        if not native_subagents or native_subagents not in ALLOWED_NATIVE_SUBAGENTS:
            fail(
                f"{prefix} nativeSubagents: invalid nativeSubagents {native_subagents!r} "
                f"(expected off or inherit)"
            )


def validate_repair_supervisor_no_native_subagents(obj: dict, prefix: str, phase_name: str) -> None:
    """Repair integrate/gate/reintegrate are supervisor-owned; reject the field."""
    if "nativeSubagents" in obj:
        fail(
            f"{prefix} nativeSubagents: repairRounds.{phase_name} nodes do not take "
            f"nativeSubagents (supervisor-owned)"
        )
    if "subagents" in obj:
        fail(
            f"{prefix} subagents: was removed. Supervisor repairRounds.{phase_name} "
            f"nodes do not take nativeSubagents."
        )
    validate_instructions_allowed(
        obj, prefix, False, f"repairRounds.{phase_name} nodes"
    )


def validate_repair_agent_instructions(obj: dict, prefix: str) -> None:
    """Repair diagnose/lanes may carry non-empty inline instructions text."""
    validate_instructions_allowed(obj, prefix, True, "repair diagnose/lanes")


def expand_repair_rounds_nodes(rr: dict) -> tuple[list, list]:
    """Expand a pipeline.repairRounds authoring macro (v2-repair-epochs) into
    synthetic graph nodes + edges, in the same shape build_graph_edges/the
    stage-compile loop emit. Purely additive: never mutates pipeline.stages.

    Bounded acyclic sequence per compiled graph, regardless of the configured
    round count (unused rounds stay in the compiled graph but are unreachable
    and skip-cascade at runtime, never mutated in): an entry integrate + gate,
    then `rounds` repeats of diagnose -> repair lanes (parallel) -> reintegrate
    -> regate. Every regate's passed branch converges on a single "<id>-passed"
    join node so downstream stages have one stable success id regardless of
    which round exits. Only the final round's regate omits a changes-required
    edge, so an exhausted repair epoch fails closed (via the existing
    gate-changes-required-no-edge scheduler path) rather than silently
    succeeding.
    """
    epoch_id = as_text(rr.get("id", "")) or "repair"
    rounds = rr.get("rounds", 2)
    if not isinstance(rounds, int) or isinstance(rounds, bool) or rounds < 0 or rounds > REPAIR_ROUNDS_HARD_MAX:
        fail(f"repairRounds.rounds must be an integer between 0 and {REPAIR_ROUNDS_HARD_MAX}")
    lanes = rr.get("lanes", [])
    if rounds > 0 and not lanes:
        fail("repairRounds.lanes must declare at least one repair lane when rounds > 0")
    lane_ids: list = []
    for lane in lanes:
        lane_id = as_text(lane.get("id", ""))
        if not lane_id:
            fail("repairRounds lane missing id")
        if lane_id in lane_ids:
            fail(f"repairRounds lane id {lane_id!r} is duplicated")
        lane_ids.append(lane_id)

    depends_on = [_parse_dep_entry(item)[0] for item in rr.get("dependsOn", []) if _parse_dep_entry(item)[0]]

    nodes: list = []
    edges: list = []

    def _mk_phase_stage(phase_key: str, node_id: str) -> dict:
        base = dict(rr.get(phase_key, {}) or {})
        base.pop("content", None)
        base.pop("verification", None)
        base["id"] = node_id
        return base

    def _add_edge(src: str, dst: str, condition: str = "") -> None:
        edge = {"from": src, "to": dst, "reasons": ["repair-epoch"]}
        if condition:
            edge["condition"] = condition
        edges.append(edge)

    integrate_id = f"{epoch_id}-integrate"
    gate_id = f"{epoch_id}-gate"
    passed_id = f"{epoch_id}-passed"

    integrate_stage = _mk_phase_stage("integrate", integrate_id)
    validate_repair_supervisor_no_native_subagents(integrate_stage, "repairRounds.integrate", "integrate")
    integrate_compiled = build_orch_stage(integrate_stage, [])
    integrate_compiled.pop("nativeSubagents", None)
    integrate_compiled["delegation"] = resolved_delegation(integrate_stage)
    nodes.append({"id": integrate_id, "type": "integrate", "dependsOn": list(depends_on), "derivedFrom": "repair-epoch", "stage": integrate_compiled})
    for dep in depends_on:
        _add_edge(dep, integrate_id)

    gate_stage = _mk_phase_stage("gate", gate_id)
    validate_repair_supervisor_no_native_subagents(gate_stage, "repairRounds.gate", "gate")
    gate_compiled = build_orch_stage(gate_stage, [])
    gate_compiled.pop("nativeSubagents", None)
    gate_compiled["delegation"] = resolved_delegation(gate_stage)
    nodes.append({"id": gate_id, "type": "gate", "dependsOn": [integrate_id], "derivedFrom": "repair-epoch", "stage": gate_compiled})
    _add_edge(integrate_id, gate_id)

    join_stage = build_orch_stage({"id": passed_id, "type": "join"}, [])
    join_stage.pop("nativeSubagents", None)
    join_stage["delegation"] = resolved_delegation({"id": passed_id})
    nodes.append({"id": passed_id, "type": "join", "dependsOn": [], "derivedFrom": "repair-epoch", "stage": join_stage})
    _add_edge(gate_id, passed_id, "passed")

    prev_gate_id = gate_id
    for n in range(1, rounds + 1):
        diagnose_id = f"{epoch_id}-r{n}-diagnose"
        # Deterministic path convention (v2-feedback-routing): both artifacts
        # live at ids fixed by this compile, so a repair plan can be pointed
        # at their exact paths even though the run-scoped {{ARTIFACT_NS}}
        # token only resolves at dispatch time.
        gate_result_ref = f"artifacts/{{{{ARTIFACT_NS}}}}/gate/{prev_gate_id}/gate-result.json"
        diagnosis_ref = f"artifacts/{{{{ARTIFACT_NS}}}}/diagnose/{diagnose_id}/diagnosis.json"
        diag_stage = _mk_phase_stage("diagnose", diagnose_id)
        if not as_text(diag_stage.get("runtime", "")):
            fail("repairRounds.diagnose must declare runtime when rounds > 0")
        validate_optional_role_reject_agent(diag_stage, "repairRounds.diagnose")
        validate_repair_agent_native_subagents(diag_stage, "repairRounds.diagnose")
        validate_repair_agent_instructions(diag_stage, "repairRounds.diagnose")
        diag_stage.pop("agent", None)
        diag_stage.pop("agentSource", None)
        diag_stage.pop("role", None)
        diag_content = as_text((rr.get("diagnose", {}) or {}).get("content", "")) or (
            f"Diagnose gate failures from {prev_gate_id} for round {n} of repair epoch {epoch_id!r}. "
            "Run the deterministic path-ownership analyzer first (graph_diagnose.sh / graph_diagnose.py "
            f"analyze against {gate_result_ref}): it maps each failure to its owning write scope and "
            f"repair lane by matching implicated files against declared writeScopes, writing {diagnosis_ref}. "
            "Only reason about a finding yourself when the analyzer marks it ambiguous (its files match more "
            "than one lane's writeScopes); you may then assign it to one of that finding's own candidate "
            "lanes, never to a lane outside its declared write scope. Do not paste raw unbounded log output "
            "into your response -- use the analyzer's bounded failureSummary."
        )
        diag_todo = {"id": f"{diagnose_id}-1", "content": diag_content, "verification": as_text((rr.get("diagnose", {}) or {}).get("verification", "")), "status": "pending"}
        diag_compiled = build_orch_stage(diag_stage, [diag_todo])
        diag_compiled["delegation"] = resolved_delegation(diag_stage)
        nodes.append({"id": diagnose_id, "type": "agent", "dependsOn": [prev_gate_id], "derivedFrom": "repair-epoch", "stage": diag_compiled})
        _add_edge(prev_gate_id, diagnose_id, "changes-required")

        lane_node_ids: list = []
        for lane in lanes:
            lane_id = as_text(lane.get("id", ""))
            if not as_text(lane.get("runtime", "")):
                fail(f"repairRounds lane {lane_id!r} must declare runtime")
            validate_optional_role_reject_agent(lane, f"repairRounds lane {lane_id!r}")
            validate_repair_agent_native_subagents(lane, f"repairRounds lane {lane_id!r}")
            validate_repair_agent_instructions(lane, f"repairRounds lane {lane_id!r}")
            lane_content = as_text(lane.get("content", ""))
            if not lane_content:
                fail(f"repairRounds lane {lane_id!r} must declare content: it is the TODO the lane keeps fixing")
            lane_node_id = f"{epoch_id}-r{n}-repair-{lane_id}"
            # Inject the diagnosis and exact gate artifact paths into the
            # reopened repair plan so the lane sees the integrated failing
            # state (via the gate result) plus its own owning findings (via
            # the diagnosis laneAssignments for this exact node id), without
            # widening its declared repair scope.
            lane_content = (
                f"{lane_content}\n\n"
                f"Diagnosis: {diagnosis_ref} (see laneAssignments[{lane_node_id!r}] for the findings you own)\n"
                f"Gate result: {gate_result_ref}\n"
                "You may only change files within your declared writeScopes."
            )
            lane_stage = dict(lane)
            lane_stage.pop("content", None)
            lane_stage.pop("verification", None)
            lane_stage.pop("agent", None)
            lane_stage.pop("agentSource", None)
            lane_stage.pop("role", None)
            lane_stage["id"] = lane_node_id
            lane_todo = {"id": f"{lane_node_id}-1", "content": lane_content, "verification": as_text(lane.get("verification", "")), "status": "pending"}
            lane_compiled = build_orch_stage(lane_stage, [lane_todo])
            lane_compiled["delegation"] = resolved_delegation(lane_stage)
            nodes.append({"id": lane_node_id, "type": "agent", "dependsOn": [diagnose_id], "derivedFrom": "repair-epoch", "stage": lane_compiled})
            _add_edge(diagnose_id, lane_node_id)
            lane_node_ids.append(lane_node_id)

        reintegrate_id = f"{epoch_id}-r{n}-reintegrate"
        reint_stage = _mk_phase_stage("reintegrate", reintegrate_id)
        validate_repair_supervisor_no_native_subagents(reint_stage, "repairRounds.reintegrate", "reintegrate")
        reint_compiled = build_orch_stage(reint_stage, [])
        reint_compiled.pop("nativeSubagents", None)
        reint_compiled["delegation"] = resolved_delegation(reint_stage)
        nodes.append({"id": reintegrate_id, "type": "integrate", "dependsOn": list(lane_node_ids), "derivedFrom": "repair-epoch", "stage": reint_compiled})
        for lane_node_id in lane_node_ids:
            _add_edge(lane_node_id, reintegrate_id)

        regate_id = f"{epoch_id}-r{n}-regate"
        regate_stage = _mk_phase_stage("gate", regate_id)
        validate_repair_supervisor_no_native_subagents(regate_stage, f"repairRounds round {n} regate", "gate")
        regate_compiled = build_orch_stage(regate_stage, [])
        regate_compiled.pop("nativeSubagents", None)
        regate_compiled["delegation"] = resolved_delegation(regate_stage)
        nodes.append({"id": regate_id, "type": "gate", "dependsOn": [reintegrate_id], "derivedFrom": "repair-epoch", "stage": regate_compiled})
        _add_edge(reintegrate_id, regate_id)
        _add_edge(regate_id, passed_id, "passed")
        # Only the last round omits a changes-required edge out of regate: an
        # exhausted repair epoch fails closed via the scheduler's existing
        # gate-changes-required-no-edge path (see graph-schedule.sh), never a
        # silent success. Earlier rounds route changes-required to the next
        # round's diagnose node.
        if n < rounds:
            prev_gate_id = regate_id

    return nodes, edges


def expand_rework_nodes(stage: dict, stages_by_id: dict, todos_by_stage: dict, iterations: int) -> tuple[list, list]:
    """Expand a graph-mode loopBackTo review stage into its bounded acyclic
    rework node/edge sequence (v2-graph-rework). Purely additive: never
    mutates pipeline.stages. This assumes the authoring-time constraints
    validate_loop_rules already enforces: loopBackTo names a direct
    dependsOn dependency of the review stage, neither the review stage nor
    its target use planFile, and loopCheck.schema matches
    GRAPH_REWORK_EVALUATOR_SCHEMA.

    Emits, for n in 1..iterations: a copy of the loopBackTo target
    (`<target>-r<n>`) and a copy of the review stage (`<review>-r<n>`), plus
    a single `<review>-approved` join node that every review generation
    (the original and every round copy) reaches on a passed edge. Only the
    final round's changes-required edge is conditional on onExhausted: fail
    (or unset) omits it so an exhausted rework loop fails closed via the
    scheduler's existing review-changes-required-no-edge path; proceed
    instead routes the final round's changes-required edge to the approved
    join.
    """
    review_id = as_text(stage.get("id", ""))
    target_id = as_text(stage.get("loopBackTo", ""))
    target = stages_by_id[target_id]
    loop_check = normalize_loop_check(stage.get("loopCheck", {}))
    verdict_path_template = loop_check.get("path", "")
    verdict_schema = loop_check.get("schema", "")
    on_exhausted = as_text(stage.get("onExhausted", "")) or "fail"

    nodes: list = []
    edges: list = []

    def _add_edge(src: str, dst: str, condition: str = "") -> None:
        edge = {"from": src, "to": dst, "reasons": ["rework"]}
        if condition:
            edge["condition"] = condition
        edges.append(edge)

    def _clone_todos(orig_stage_id: str, new_stage_id: str) -> list:
        cloned = []
        for idx, td in enumerate(todos_by_stage.get(orig_stage_id, []), start=1):
            cloned.append(
                {
                    "id": f"{new_stage_id}-{idx}",
                    "content": as_text(td.get("content", "")),
                    "verification": as_text(td.get("verification", "")),
                    "status": "pending",
                }
            )
        return cloned

    def _clone_stage(orig_stage: dict, new_id: str) -> dict:
        # Only identity, dependency routing, and (for target rounds) the
        # added verdict requirement change; every other field -- runtime,
        # agent, model, sessionStrategy, contextBudget, workspaceMode,
        # tooling profile, delegation policy, write scopes, agentGitAccess,
        # shared-mutation policy, and inline todos -- is reused verbatim from
        # the stage this copies. dependsOn/loopBackTo/loopCheck/onExhausted/
        # maxIterations are macro-routing fields owned by this expansion, not
        # the compiled node, so they are dropped rather than copied: the
        # explicit rework edges/dependsOn below are the only routing that
        # applies to derived nodes.
        cloned = dict(orig_stage)
        cloned["id"] = new_id
        cloned.pop("dependsOn", None)
        cloned.pop("loopBackTo", None)
        cloned.pop("loopCheck", None)
        cloned.pop("onExhausted", None)
        cloned.pop("maxIterations", None)
        return cloned

    approved_id = f"{review_id}-approved"
    approved_stage = build_orch_stage({"id": approved_id, "type": "join"}, [])
    approved_stage["delegation"] = resolved_delegation({"id": approved_id})
    nodes.append({"id": approved_id, "type": "join", "dependsOn": [], "derivedFrom": "rework", "stage": approved_stage})
    _add_edge(review_id, approved_id, "passed")

    prev_review_id = review_id
    for n in range(1, iterations + 1):
        target_round_id = f"{target_id}-r{n}"
        review_round_id = f"{review_id}-r{n}"

        # Preserve {{ARTIFACT_NS}} but pre-resolve {{STAGE_ID}} to the exact
        # preceding review node id: the ordinary dispatch-time substitution
        # of {{STAGE_ID}} would resolve to the *consuming* node's own id
        # (target_round_id), not the review node that actually produced the
        # verdict, since that substitution always uses RALPH_GRAPH_NODE_ID.
        verdict_path = verdict_path_template.replace("{{STAGE_ID}}", prev_review_id)
        verdict_requirement = {"path": verdict_path, "required": True}
        if verdict_schema:
            verdict_requirement["schema"] = verdict_schema

        target_stage = _clone_stage(target, target_round_id)
        target_stage["requires"] = raw_artifacts(target.get("requires", []) or []) + [verdict_requirement]
        target_compiled = build_orch_stage(target_stage, _clone_todos(target_id, target_round_id))
        target_compiled["delegation"] = resolved_delegation(target_stage)
        nodes.append(
            {
                "id": target_round_id,
                "type": "agent",
                "dependsOn": [prev_review_id],
                "derivedFrom": "rework",
                "stage": target_compiled,
            }
        )
        _add_edge(prev_review_id, target_round_id, "changes-required")

        review_stage = _clone_stage(stage, review_round_id)
        review_compiled = build_orch_stage(review_stage, _clone_todos(review_id, review_round_id))
        review_compiled["delegation"] = resolved_delegation(review_stage)
        nodes.append(
            {
                "id": review_round_id,
                "type": "agent",
                "dependsOn": [target_round_id],
                "derivedFrom": "rework",
                "stage": review_compiled,
            }
        )
        _add_edge(target_round_id, review_round_id)
        _add_edge(review_round_id, approved_id, "passed")

        if n < iterations:
            prev_review_id = review_round_id
        elif on_exhausted == "proceed":
            _add_edge(review_round_id, approved_id, "changes-required")

    return nodes, edges


if mode == "rework-debug":
    if not frontmatter.get("_pipeline_present"):
        fail("rework-debug mode requires a pipeline block")
    stage_id, _, iter_str = target.partition(":")
    try:
        iterations = int(iter_str)
    except ValueError:
        fail("rework-debug mode target must be '<review-stage-id>:<iterations>'")
    if stage_id not in stages_by_id:
        fail(f"rework-debug mode: unknown stage {stage_id!r}")
    todos_by_stage_debug: dict = {}
    for item in todos:
        todos_by_stage_debug.setdefault(as_text(item.get("stage", "")), []).append(item)
    debug_nodes, debug_edges = expand_rework_nodes(
        stages_by_id[stage_id], stages_by_id, todos_by_stage_debug, iterations
    )
    print(json.dumps({"nodes": debug_nodes, "edges": debug_edges}, separators=(",", ":"), ensure_ascii=False))
    raise SystemExit(0)

if mode == "graph":
    if not frontmatter.get("_pipeline_present"):
        fail("graph mode requires a pipeline block")
    import os
    base = os.path.basename(plan_path)
    for suffix in (".plan.md", ".md"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    name = frontmatter.get("name", "") or base
    namespace = _resolve_artifact_namespace(frontmatter.get("namespace", ""), base)
    todos_by_stage: dict = {}
    for item in todos:
        todos_by_stage.setdefault(as_text(item.get("stage", "")), []).append(item)

    graph_producers, _graph_external_preconditions = build_graph_artifact_maps(stages, todos)
    # Map of consensus stage id -> list of voter ids. Populated below during
    # node expansion and consumed afterwards to rewrite edges that reference
    # the bare consensus root id (which is not a real node after expansion).
    consensus_voter_map: dict = {}
    graph_nodes = []
    for stage in stages:
        stage_id = as_text(stage.get("id", ""))
        stage_type = as_text(stage.get("type", "")) or "agent"
        if stage_type == "consensus":
            voters = stage.get("voters", [])
            voter_id_list = [as_text(v.get("id", "")) for v in voters if as_text(v.get("id", ""))]
            consensus_voter_map[stage_id] = voter_id_list
            for voter in voters:
                voter_id = as_text(voter.get("id", ""))
                if not voter_id:
                    continue
                # Force sessionStrategy=fresh on every voter. A voter that can
                # see another voter's session is not an independent reviewer;
                # the entire value of cross-provider consensus comes from
                # isolation. This mirrors the grader precedent which already
                # requires fresh and forbids resuming the writer session. Do not
                # relax this for symmetry with other node types: the isolation
                # invariant is load-bearing for the correctness of the jury.
                #
                # Force nativeSubagents=off on every voter. Ambient native
                # subagents make the recorded provenance (runtime, model)
                # inaccurate and add variance to the one measurement that must
                # be a clean independent sample. Validate_stage already rejects
                # nativeSubagents other than off at parse time; this forced-off
                # here is the defense-in-depth expansion-time guarantee. Do not
                # relax this for symmetry with other node types: voters are not
                # covered by the ordinary agent-stage off|inherit contract.
                #
                # Each voter owns optional instructions independently: never
                # inherit removed role/agent or instructions from the consensus
                # stage, the reviewed stage, or another voter.
                voter_stage = {
                    **stage,
                    "id": f"{stage_id}:{voter_id}",
                    "runtime": as_text(voter.get("runtime", "")) or as_text(stage.get("runtime", "")),
                    "model": as_text(voter.get("model", "")) or as_text(stage.get("model", "")),
                    "sessionStrategy": "fresh",
                    "contextBudget": as_text(voter.get("contextBudget", "")) or as_text(stage.get("contextBudget", "")),
                    "nativeSubagents": "off",
                    "produces": substitute_voter_id_in_artifacts(
                        stage.get("produces", []) or [], voter_id
                    ),
                    "requires": substitute_voter_id_in_artifacts(
                        stage.get("requires", []) or [], voter_id
                    ),
                }
                voter_stage.pop("agent", None)
                voter_stage.pop("agentSource", None)
                voter_stage.pop("role", None)
                voter_stage.pop("subagents", None)
                voter_stage.pop("instructions", None)
                voter_instructions = as_text(voter.get("instructions", ""))
                if voter_instructions:
                    voter_stage["instructions"] = voter_instructions
                compiled_voter_stage = build_orch_stage(voter_stage, todos_by_stage.get(stage_id, []))
                compiled_voter_stage["nativeSubagents"] = "off"
                compiled_voter_stage["delegation"] = resolved_delegation(voter_stage)
                graph_nodes.append(
                    {
                        "id": f"{stage_id}:{voter_id}",
                        "type": "consensus-voter",
                        "dependsOn": [stage_id],
                        "derivedFrom": "consensus",
                        "stage": compiled_voter_stage,
                    }
                )
            graph_nodes.append(
                {
                    "id": f"{stage_id}:barrier",
                    "type": "consensus-barrier",
                    "dependsOn": [f"{stage_id}:{as_text(voter.get('id', ''))}" for voter in voters if as_text(voter.get("id", ""))],
                    "derivedFrom": "consensus",
                    "stage": build_orch_stage(
                        {
                            **stage,
                            "id": f"{stage_id}:barrier",
                            "type": "join",
                            # Strip voter-specific artifact paths from the barrier.
                            # Each voter node owns its own per-voter produces; the
                            # barrier is a synchronization join and must not claim
                            # to produce artifacts that carry an unresolvable
                            # {{VOTER_ID}} token.
                            "produces": [
                                item
                                for item in (stage.get("produces", []) or [])
                                if "{{VOTER_ID}}" not in as_text(item.get("path", ""))
                            ],
                            "requires": [
                                item
                                for item in (stage.get("requires", []) or [])
                                if "{{VOTER_ID}}" not in as_text(item.get("path", ""))
                            ],
                        },
                        todos_by_stage.get(stage_id, []),
                    ),
                }
            )
            continue
        compiled_stage = build_orch_stage(stage, todos_by_stage.get(stage_id, []))
        compiled_stage["delegation"] = resolved_delegation(stage)
        node = {
            "id": stage_id,
            "type": stage_type,
            "dependsOn": [_parse_dep_entry(item)[0] for item in stage.get("dependsOn", []) if _parse_dep_entry(item)[0]],
            "derivedFrom": "stage",
            "stage": compiled_stage,
        }
        graph_nodes.append(node)

    # Expand the v2-repair-epochs compile-time macro, if declared, into its
    # bounded acyclic node/edge sequence. This never mutates pipeline.stages
    # or the nodes/edges above; it is purely additive.
    repair_rounds_cfg = frontmatter["pipeline"].get("repairRounds")
    repair_epoch_edges: list = []
    if repair_rounds_cfg:
        repair_epoch_nodes, repair_epoch_edges = expand_repair_rounds_nodes(repair_rounds_cfg)
        graph_nodes.extend(repair_epoch_nodes)

    # Expand each authored loopBackTo review stage into its bounded acyclic
    # rework node/edge sequence (v2-graph-rework), purely additive to the
    # nodes/edges built above. Every existing node's dependsOn that names a
    # rework review stage is rewritten to depend on that review's
    # <review>-approved join instead, so downstream consumers converge
    # through every rework round rather than racing the first pass. The
    # rework expansion's own derived nodes (the -r<n> copies) are exempt:
    # their dependsOn already routes through the correct round-specific
    # predecessor and must not be reset back to the original review id.
    pipeline_max_rework_iterations = frontmatter["pipeline"].get("maxReworkIterations", "")
    rework_nodes: list = []
    rework_edges: list = []
    rework_review_ids: set = set()
    rework_loop_checks: dict = {}
    for _rw_stage in stages:
        _rw_stage_id = as_text(_rw_stage.get("id", ""))
        if not as_text(_rw_stage.get("loopBackTo", "")):
            continue
        _rw_max_iterations = _rw_stage.get("maxIterations", "")
        _rw_iterations = (
            _rw_max_iterations if isinstance(_rw_max_iterations, int) else pipeline_max_rework_iterations
        )
        if not isinstance(_rw_iterations, int) or _rw_iterations < 1:
            continue
        _rw_loop_check = normalize_loop_check(_rw_stage.get("loopCheck", {}))
        if _rw_loop_check:
            rework_loop_checks[_rw_stage_id] = _rw_loop_check
            for _rw_n in range(1, _rw_iterations + 1):
                rework_loop_checks[f"{_rw_stage_id}-r{_rw_n}"] = _rw_loop_check
        _rw_nodes, _rw_edges = expand_rework_nodes(_rw_stage, stages_by_id, todos_by_stage, _rw_iterations)
        rework_nodes.extend(_rw_nodes)
        rework_edges.extend(_rw_edges)
        rework_review_ids.add(_rw_stage_id)

    if rework_review_ids:
        for _node in graph_nodes:
            _node["dependsOn"] = [
                f"{_d}-approved" if _d in rework_review_ids else _d for _d in _node.get("dependsOn", [])
            ]
    graph_nodes.extend(rework_nodes)

    # Graph node stages never carry loopControl: the scheduler does not read
    # it, and its orchestration-only shape is misleading in the frozen
    # graph. Loop-check verdict gating for review nodes is instead expressed
    # via each review node's own loopCheck field (original and every
    # derived round copy), set explicitly here since build_orch_stage does
    # not emit it and _clone_stage strips it from round copies.
    # loopCheck paths/schemas are stage-authored only; roles never invent
    # evaluator verdicts, rework evidence paths, or loop conditions.
    for _node in graph_nodes:
        _node["stage"].pop("loopControl", None)
        _node_loop_check = rework_loop_checks.get(_node["id"])
        if _node_loop_check:
            _node["stage"]["loopCheck"] = _node_loop_check

    # Every graph node carries a concrete, audit-ready policy in the frozen
    # graph/ledger, including nodes whose source omitted delegation entirely.
    # Agent nodes also carry resolved nativeSubagents (default off).
    for _node in graph_nodes:
        _node["stage"].setdefault("delegation", resolved_delegation(_node["stage"]))
        if as_text(_node.get("type", "")) in {"agent", "stage"}:
            _node["stage"].setdefault("nativeSubagents", "off")
    graph_nodes.sort(key=lambda item: item["id"])

    raw_edges = build_graph_edges(
        stages,
        todos,
        graph_producers,
        as_text(frontmatter["pipeline"].get("edgeDerivation", "both")) or "both",
        bool(frontmatter["pipeline"].get("strictEdges", False)),
    )
    raw_edges.extend(repair_epoch_edges)
    if rework_review_ids:
        for _edge in raw_edges:
            if _edge.get("from") in rework_review_ids:
                _edge["from"] = f"{_edge['from']}-approved"
    raw_edges.extend(rework_edges)
    # Inject synthetic voter->barrier edges for every consensus stage.
    # build_graph_edges only processes the original pipeline.stages list and has
    # no knowledge of the synthetic voter/barrier nodes created during consensus
    # expansion, so these edges are never emitted by the normal edge-builder.
    # Without them the barrier's indegree in the scheduler is 0, causing it to
    # be dispatched immediately (concurrently with its voters) instead of after
    # all voters succeed.
    for _cstage_id, _voter_ids in consensus_voter_map.items():
        for _vid in _voter_ids:
            raw_edges.append(
                {"from": f"{_cstage_id}:{_vid}", "to": f"{_cstage_id}:barrier", "reasons": ["consensus-barrier"]}
            )
    # Rewrite any edge that references a bare consensus root id.
    # - edge.to == consensus root id  -> redirect to <root>:barrier
    # - edge.from == consensus root id -> fan out to each <root>:<voter_id>
    # Both rewrites can apply simultaneously when both endpoints are consensus
    # root ids. Dedup uses the same reason-merging pattern as build_graph_edges.
    rewritten: dict = {}

    def _rewrite_add(src: str, dst: str, reasons: list, condition: str = "") -> None:
        key = f"{src}\0{dst}\0{condition}"
        if key not in rewritten:
            rewritten[key] = {"from": src, "to": dst, "reasons": list(reasons), "condition": condition}
        else:
            for r in reasons:
                if r not in rewritten[key]["reasons"]:
                    rewritten[key]["reasons"].append(r)

    for _edge in raw_edges:
        _src = _edge["from"]
        _dst = _edge["to"]
        _reasons = _edge.get("reasons", [])
        _condition = _edge.get("condition", "")
        # from=consensus_root means the group is upstream; the downstream node
        # must wait for the group's terminal barrier node, not each individual
        # voter. Redirect: consensus_root -> X  becomes  consensus_root:barrier -> X.
        _effective_srcs = [f"{_src}:barrier"] if _src in consensus_voter_map else [_src]
        # to=consensus_root means the group is downstream; each voter individually
        # needs the upstream input before it can run. Fan out:
        # X -> consensus_root  becomes  X -> consensus_root:voter for each voter.
        _effective_dsts = (
            [f"{_dst}:{_vid}" for _vid in consensus_voter_map[_dst]]
            if _dst in consensus_voter_map
            else [_dst]
        )
        for _esrc in _effective_srcs:
            for _edst in _effective_dsts:
                _rewrite_add(_esrc, _edst, _reasons, _condition)

    rewritten_edges = list(rewritten.values())
    # Strip empty condition field from edges before output (backward compat).
    for _re in rewritten_edges:
        if not _re.get("condition", ""):
            _re.pop("condition", None)

    result = {
        "schemaVersion": 2,
        "ralphVersion": get_ralph_version(),
        "name": name,
        "namespace": namespace,
        "maxParallel": frontmatter["pipeline"].get("maxParallel", graph_contract_default("maxParallel", 3)),
        "edgeDerivation": frontmatter["pipeline"].get("edgeDerivation", graph_contract_default("edgeDerivation", "both")),
        "failurePolicy": frontmatter["pipeline"].get("failurePolicy", graph_contract_default("failurePolicy", "drain")),
        "strictEdges": bool(frontmatter["pipeline"].get("strictEdges", graph_contract_default("strictEdges", False))),
        "publishMode": frontmatter["pipeline"].get("publishMode", graph_contract_default("publishMode", "manual")),
        "nodes": graph_nodes,
        "edges": rewritten_edges,
    }
    ralph_mode = frontmatter["pipeline"].get("ralphMode", "")
    if ralph_mode:
        result["ralphMode"] = ralph_mode
    tooling_cfg = frontmatter["pipeline"].get("tooling")
    if tooling_cfg:
        result["tooling"] = tooling_cfg
    verification_profiles = frontmatter["pipeline"].get("verificationProfiles", [])
    if verification_profiles:
        result["verificationProfiles"] = verification_profiles
    print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
    raise SystemExit(0)

todo = resolve_target(todos, target)
stage = stage_defaults_for(todo, stages_by_id)

if mode == "raw":
    result = build_raw_metadata(todo)
elif mode == "effective":
    result = build_effective_metadata(todo, stage, plan_runtime=plan_runtime)
else:
    fail(f"unsupported mode {mode!r}")

print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
PYTHON
}

plan_pipeline_todo_metadata_json() {
  _plan_pipeline_metadata_json "$1" "$2" "raw"
}

plan_pipeline_effective_metadata_json() {
  _plan_pipeline_metadata_json "$1" "$2" "effective"
}

# Emit the full .orch.json-shaped document (name/namespace/stages[]/parallelStages[])
# for a structured orchestration plan. The target argument is ignored.
plan_pipeline_orch_json() {
  _plan_pipeline_metadata_json "$1" "__orch__" "orch"
}

plan_pipeline_graph_json() {
  _plan_pipeline_metadata_json "$1" "__graph__" "graph"
}

# Emit {"nodes":[...],"edges":[...]} for the graph-mode rework expansion of
# a single loopBackTo review stage, without compiling the full graph. Used
# to introspect/test expand_rework_nodes directly: $2 is the review stage
# id, $3 is the iteration count to expand.
plan_pipeline_rework_debug_json() {
  _plan_pipeline_metadata_json "$1" "$2:$3" "rework-debug"
}

plan_structured_todo_metadata_json() {
  plan_pipeline_todo_metadata_json "$@"
}

plan_structured_effective_metadata_json() {
  plan_pipeline_effective_metadata_json "$@"
}

get_next_todo() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || return 1

  if plan_format_is_yaml "$format"; then
    plan_yaml_frontmatter_op "$plan_path" "get_next"
    return $?
  else
    local line_num=0
    local block=""
    local capturing=0
    local start_line=0
    local line next_line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_num=$((line_num + 1))
      if [[ "$capturing" == "0" ]]; then
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]]; then
          block="$line"
          start_line="$line_num"
          capturing=1
        fi
        continue
      fi

      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]] || [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]]* ]] || [[ "$line" =~ ^#{1,6}[[:space:]] ]] || [[ "$line" =~ ^---[[:space:]]*$ ]]; then
        printf '%s|%s\n' "$start_line" "$block"
        return 0
      fi

      if [[ -n "${line//[[:space:]]/}" ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
        printf '%s|%s\n' "$start_line" "$block"
        return 0
      fi

      block+=$'\n'"$line"
    done < "$plan_path"
    if [[ "$capturing" == "1" ]]; then
      printf '%s|%s\n' "$start_line" "$block"
      return 0
    fi
  fi
  return 1
}

plan_mark_todo_done_at_line() {
  local plan_path="$1"
  local plan_line="$2"
  local tmp line_nr=0 changed=0 line

  [[ -f "$plan_path" ]] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-plan-done.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_nr=$((line_nr + 1))
    if (( line_nr == plan_line )) && [[ "$line" =~ ^([[:space:]]*-[[:space:]]+)\[[[:space:]]\]([[:space:]]*)(.*)$ ]]; then
      printf '%s[x]%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >>"$tmp"
      changed=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$plan_path"
  if (( changed == 0 )); then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$plan_path"
  return 0
}

plan_mark_todo_done_by_format() {
  local plan_path="$1"
  local format="${2:-}"
  local line_or_content="$3"

  if plan_format_is_yaml "$format"; then
    plan_mark_todo_done_yaml "$plan_path" "$line_or_content"
  else
    plan_mark_todo_done_at_line "$plan_path" "$line_or_content"
  fi
}

count_todos() {
  local plan_path="$1"
  local format
  format="$(plan_detect_format "$plan_path")" || { printf '0 0\n'; return 1; }

  if plan_format_is_yaml "$format"; then
    plan_yaml_frontmatter_op "$plan_path" "count"
  else
    local total=0
    local done=0
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]* ]]; then
        total=$((total + 1))
      elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]] ]]; then
        total=$((total + 1))
        done=$((done + 1))
      fi
    done < "$plan_path"
    printf '%s %s\n' "$done" "$total"
  fi
}

# 1-based index of the checklist item at plan_path line plan_line (counts both open and done
# items in file order through that line). For default markdown, the open TODO line from get_next_todo matches.
# YAML frontmatter plans do not use file-line semantics for get_next_todo's first field; use plan_todo_ordinal_for_next.
plan_todo_ordinal_at_line() {
  local plan_path="$1"
  local plan_line="$2"
  awk -v ln="$plan_line" '
    NR > ln { exit }
    /^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*/ { c++; next }
    /^[[:space:]]*-[[:space:]]+\[x\][[:space:]]/ { c++; next }
    END { print c + 0 }
  ' "$plan_path"
}

# plan_path, plan format ('default' or 'yaml'), first field from get_next_todo (line number or YAML ordinal).
plan_todo_ordinal_for_next() {
  local plan_path="$1"
  local format="${2:-default}"
  local next_first_field="$3"

  if plan_format_is_yaml "$format"; then
    printf '%s\n' "$next_first_field"
  else
    plan_todo_ordinal_at_line "$plan_path" "$next_first_field"
  fi
}

# True when TODO wording means the operator should be consulted via the runner (pending-human),
# not only via assistant chat (which the runner does not treat as blocking).
plan_todo_implies_operator_dialog() {
  local t="$1"
  # "Tell the user ..." is usually a one-way message via assistant output; do not require a gate.
  [[ "$t" =~ [Aa]sk[[:space:]]+the[[:space:]]+user ]] && return 0
  return 1
}

# Reopen the checklist item at 1-based plan_line (change [x] to [ ]). Returns 0 if a line was changed.
plan_reopen_todo_at_line() {
  local plan_path="$1"
  local plan_line="$2"
  local tmp line_nr=0 changed=0 line

  [[ -f "$plan_path" ]] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-plan-reopen.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_nr=$((line_nr + 1))
    if (( line_nr == plan_line )) && [[ "$line" =~ ^([[:space:]]*-[[:space:]]+)\[[xX]\]([[:space:]]*)(.*)$ ]]; then
      printf '%s[ ]%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >>"$tmp"
      changed=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$plan_path"
  if (( changed == 0 )); then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$plan_path"
  return 0
}

plan_reopen_todo_yaml() {
  local plan_path="$1"
  local todo_content="$2"
  plan_yaml_update_todo_status "$plan_path" "$todo_content" "pending"
}

plan_reopen_todo_cursor() {
  plan_reopen_todo_yaml "$@"
}

plan_reopen_todo_by_format() {
  local plan_path="$1"
  local format="${2:-}"
  local line_or_content="$3"

  if plan_format_is_yaml "$format"; then
    plan_reopen_todo_yaml "$plan_path" "$line_or_content"
  else
    plan_reopen_todo_at_line "$plan_path" "$line_or_content"
  fi
}

plan_todo_risk_classify() {
  local todo_text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$todo_text" <<'PYTHON'
import re
import sys

text = sys.argv[1]
lower = text.lower()

manual_patterns = [
    r'\bmanual\b',
    r'\bsmoke\b',
    r'\bgolden[ -]path\b',
    r'\bnot run in this session\b',
    r'\bask the user\b',
]
destructive_patterns = [
    r'\bdelete\b',
    r'\bdrop\b',
    r'\bdestroy\b',
    r'\bpurge\b',
    r'\btruncate\b',
    r'\bwipe\b',
    r'\brollback\b',
    r'\bmigrate down\b',
    r'\bdown-migrate\b',
    r'\bremove\b',
]
implementation_patterns = [
    r'\bimplement\b',
    r'\badd\b',
    r'\bupdate\b',
    r'\bfix\b',
    r'\bcreate\b',
    r'\bmodify\b',
    r'\bpatch\b',
    r'\bwire\b',
    r'\bintegrate\b',
    r'\brefactor\b',
    r'\bchange\b',
    r'\bchanges\b',
    r'\bchanged\b',
    r'\bmake\b.*\bchanges?\b',
    r'\bremove\b',
    r'\breplace\b',
    r'\bdelete\b',
    r'\binsert\b',
    r'\bwrap\b',
    r'\bdelete\b',
]
normal_patterns = [
    r'\bdocs?\b',
    r'\bdocumentation\b',
    r'\brunbook\b',
    r'\banalysis\b',
    r'\breview\b',
    r'\binvestigate\b',
    r'\bexplain\b',
    r'\bsummarize\b',
    r'\bread\b',
]

if any(re.search(pattern, lower) for pattern in manual_patterns):
    print("manual_gate")
elif any(re.search(pattern, lower) for pattern in destructive_patterns):
    print("destructive_gate")
else:
    command_prefixes = (
        "./",
        "/",
        "npm",
        "npx",
        "yarn",
        "pnpm",
        "git",
        "bash",
        "sh",
        "python",
        "python3",
        "pytest",
        "playwright",
        "node",
        "make",
        "go",
        "cargo",
        "bun",
        "deno",
        "grep",
        "rg",
        "sed",
        "awk",
        "find",
        "cat",
        "curl",
        "docker",
        "kubectl",
        "mvn",
        "gradle",
        "tsc",
        "eslint",
        "prettier",
        "vitest",
        "jest",
        "rspec",
        "bundle",
        "rake",
        "uv",
    )

    def looks_like_command(candidate: str) -> bool:
        candidate = candidate.strip()
        if not candidate:
            return False
        first = candidate.split(None, 1)[0]
        if first.startswith("./") or first.startswith("/"):
            return True
        return first in command_prefixes

    verification_hint = False
    if re.search(r'(^|\n)\s*verification\s*:', text, re.I):
        verification_hint = True
    else:
        for candidate in re.findall(r'`([^`]+)`', text):
            if looks_like_command(candidate):
                verification_hint = True
                break
        if not verification_hint and re.search(r'(^|\n).*(?:&&|\|\||;).+', text):
            verification_hint = True

    if verification_hint:
        print("verification_gate")
    elif any(re.search(pattern, lower) for pattern in implementation_patterns) and not any(re.search(pattern, lower) for pattern in normal_patterns):
        print("implementation_gate")
    else:
        print("normal")
PYTHON
  else
    printf 'normal\n'
  fi
}

_ralph_plan_verify_extract_script() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$base_dir/../python/plan_todo_extract_verification_commands.py"
}

plan_todo_extract_verification_commands() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_verify_extract_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" "$todo_text"
}

ralph_plan_verify_to_complete_command() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_verify_extract_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" verify-to-complete "$todo_text"
}

plan_todo_contains_suspicious_completion_phrase() {
  local text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$text" <<'PYTHON'
import re
import sys

text = sys.argv[1].lower()
patterns = [
    r'marked\s+.*complete',
    r'no\s+further\s+action',
    r'no\s+additional\s+steps',
    r'done\s+and\s+stop',
]
print("1" if any(re.search(pattern, text) for pattern in patterns) else "0")
PYTHON
  else
    case "$text" in
      *"marked "*complete*|*"no further action"*|*"no additional steps"*|*"done and stop"*)
        printf '1\n'
        ;;
      *)
        printf '0\n'
        ;;
    esac
  fi
}

plan_todo_autonomous_evidence_present() {
  local text="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$text" <<'PYTHON'
import re
import sys

text = sys.argv[1].lower()
patterns = [
    r'\bverified\b',
    r'\bautovalidated\b',
    r'\bplaywright\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bunit\s+test(s)?\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\btest(s)?\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bcode\s+review\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bautomated\s+check\b.*\b(pass(ed)?|succeed(ed)?|ok)\b',
    r'\bexit\s+0\b',
]
print("1" if any(re.search(pattern, text, re.I | re.S) for pattern in patterns) else "0")
PYTHON
  else
    case "$text" in
      *"VERIFIED:"*|*"AUTOVALIDATED:"*|*"PASS"*|*"PASSED"*)
        printf '1\n'
        ;;
      *)
        printf '0\n'
        ;;
    esac
  fi
}

# Consolidation implementation using Python when available, otherwise no-op with warning.
# Writes log to session dir if RALPH_SESSION_DIR is set.
ralph_run_plan_consolidate_todos() {
  local plan_path="$1"
  if [[ ! -f "$plan_path" ]]; then
    echo "Error: plan file not found for consolidation: $plan_path" >&2
    return 1
  fi

  local session_dir="${RALPH_SESSION_DIR:-}"
  local log_path
  if [[ -n "$session_dir" ]]; then
    log_path="$session_dir/consolidation-log.txt"
  else
    log_path="/dev/null"
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Warning: todo consolidation requires Python 3 (missing); skipping" >&2
    if [[ -n "$session_dir" ]]; then
      echo "$(date): Python 3 not found, consolidation skipped" >> "$log_path"
    fi
    return 0
  fi

  local base_dir share_dir
  base_dir="$(dirname "${BASH_SOURCE[0]}")"
  share_dir="$(cd "$base_dir" && pwd)"
  local script_path="$share_dir/../python/plan-todo-consolidate.py"

  if [[ ! -f "$script_path" ]]; then
    echo "Warning: consolidation script not found at $script_path; skipping" >&2
    if [[ -n "$session_dir" ]]; then
      echo "$(date): consolidation script not found, skipped" >> "$log_path"
    fi
    return 0
  fi

  python3 "$script_path" "$plan_path" "$log_path"
}

_ralph_plan_split_script() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$base_dir/../python/plan-split.py"
}

ralph_plan_split_preflight() {
  local plan_path="$1"
  local mode="${2:-warn}"
  local out_path="${3:-}"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 0
  command -v python3 &>/dev/null || {
    echo "Warning: python3 not found; skipping Ralph TODO preflight." >&2
    return 0
  }

  local args=(python3 "$script" preflight --plan "$plan_path" --mode "$mode")
  [[ -n "$out_path" ]] && args+=(--out "$out_path")
  RALPH_PLAN_MAX_TODO_BYTES="${RALPH_PLAN_MAX_TODO_BYTES:-1800}" \
  RALPH_PLAN_MAX_TODO_CONTINUATION_LINES="${RALPH_PLAN_MAX_TODO_CONTINUATION_LINES:-6}" \
  RALPH_PLAN_MAX_FILE_REFS_PER_TODO="${RALPH_PLAN_MAX_FILE_REFS_PER_TODO:-5}" \
    "${args[@]}"
}

ralph_plan_split_cli() {
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || {
    echo "Error: split helper not found: $script" >&2
    return 1
  }
  command -v python3 &>/dev/null || {
    echo "Error: split-plan requires python3." >&2
    return 1
  }
  RALPH_PLAN_MAX_TODO_BYTES="${RALPH_PLAN_MAX_TODO_BYTES:-1800}" \
  RALPH_PLAN_MAX_TODO_CONTINUATION_LINES="${RALPH_PLAN_MAX_TODO_CONTINUATION_LINES:-6}" \
  RALPH_PLAN_MAX_FILE_REFS_PER_TODO="${RALPH_PLAN_MAX_FILE_REFS_PER_TODO:-5}" \
    python3 "$script" split "$@"
}

ralph_plan_direct_verification_command() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" direct-command --todo "$todo_text"
}

ralph_plan_post_verification_command() {
  local todo_text="$1"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" post-verify-command --todo "$todo_text"
}

plan_frontmatter_verify_command() {
  local plan_path="$1"
  local script
  script="$(_ralph_plan_split_script)"
  [[ -f "$script" ]] || return 1
  command -v python3 &>/dev/null || return 1
  python3 "$script" plan-verify-command --plan "$plan_path"
}

# ---------------------------------------------------------------------------
# Supplied-plan (planInput) pure extractor / version-1 input manifest
# ---------------------------------------------------------------------------

# Absolute path of the workflow-input-plan schema (bundle-relative to this lib).
plan_provided_input_schema_path() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$here/../schemas/workflow-input-plan.schema.json"
}

# SHA-256 of file bytes. Prints 64 lowercase hex chars.
plan_provided_input_file_sha256() {
  local path="$1"
  [[ -f "$path" ]] || {
    echo "Error: plan file not found: $path" >&2
    return 1
  }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$path"
    return 0
  fi
  echo "Error: no sha256 tool available (sha256sum/shasum/python3)" >&2
  return 1
}

# Physical path for an existing file (follows symlinks).
plan_provided_input_realpath() {
  local path="$1"
  [[ -n "$path" && -e "$path" ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null && return 0
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null && return 0
  fi
  # Fallback: absolute form without full symlink chase when tools are missing.
  if [[ "$path" != /* ]]; then
    path="$(pwd -P)/$path"
  fi
  printf '%s\n' "$path"
}

# Absolutize a root that may not exist yet (for containment checks).
plan_provided_input_abs_root() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  if [[ -d "$path" ]]; then
    plan_provided_input_realpath "$path"
    return $?
  fi
  if [[ "$path" != /* ]]; then
    path="$(pwd -P)/$path"
  fi
  printf '%s\n' "${path%/}"
}

# True when resolved plan path is under one of the four allowed roots.
# Roots: project root, state root, $HOME/.cursor/plans, $HOME/.claude/plans.
plan_provided_input_under_allowed_roots() {
  local plan_real="$1"
  local project_root="$2"
  local state_root="$3"
  local root real_root
  local home_root="${HOME:-}"
  for root in "$project_root" "$state_root" \
    "${home_root}/.cursor/plans" "${home_root}/.claude/plans"; do
    [[ -n "$root" ]] || continue
    real_root="$(plan_provided_input_abs_root "$root")" || continue
    case "$plan_real" in
      "$real_root"|"$real_root"/*) return 0 ;;
    esac
  done
  return 1
}

# Classify candidate plan: leaf|workflow|graph|orchestration|missing|unsupported
plan_provided_input_shape() {
  local path="$1"
  [[ -f "$path" ]] || { printf 'missing\n'; return 0; }
  case "$path" in
    *.graph.json) printf 'graph\n'; return 0 ;;
    *.orch.json|*.json) printf 'orchestration\n'; return 0 ;;
  esac
  awk '
    NR == 1 {
      if ($0 != "---") { print "leaf"; done = 1; exit 0 }
      in_fm = 1
      next
    }
    in_fm && $0 == "---" { in_fm = 0; next }
    in_fm && /^kind:[[:space:]]*workflow([[:space:]]|$)/ { is_workflow = 1 }
    in_fm && /^execution:[[:space:]]*graph([[:space:]]|$)/ { is_graph = 1 }
    in_fm && /^execution:[[:space:]]*orchestration([[:space:]]|$)/ { is_orch = 1 }
    in_fm && /^[[:space:]]*pipeline:[[:space:]]*$/ { is_pipeline = 1 }
    END {
      if (done) exit
      if (is_workflow) print "workflow"
      else if (is_graph) print "graph"
      else if (is_pipeline || is_orch) print "orchestration"
      else print "leaf"
    }
  ' "$path"
}

# Frontmatter scalar (first match). Empty when absent / classic.
plan_provided_input_fm_scalar() {
  local path="$1"
  local key="$2"
  awk -v key="$key" '
    NR == 1 { if ($0 != "---") exit 0; in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $0 ~ ("^" key ":[[:space:]]*") {
      sub("^" key ":[[:space:]]*", "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 ~ /^".*"$/) { sub(/^"/, "", $0); sub(/"$/, "", $0) }
      if ($0 ~ /^'\''.*'\''$/) { sub(/^'\''/, "", $0); sub(/'\''$/, "", $0) }
      print $0
      exit
    }
  ' "$path"
}

# True when a classic plan body contains only invalid empty-bracket "todos" (- [])
# and no valid "- [ ]" / "- [x]" lines. Used for invalid-checkbox rejection.
plan_provided_input_has_invalid_checkbox_only() {
  local path="$1"
  local valid=0 invalid=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]xX]\] ]]; then
      valid=$((valid + 1))
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[\] ]]; then
      invalid=$((invalid + 1))
    fi
  done <"$path"
  [[ "$valid" -eq 0 && "$invalid" -gt 0 ]]
}

# UTC timestamp YYYY-MM-DDTHH:MM:SSZ
plan_provided_input_utc_now() {
  if date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then
    return 0
  fi
  python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

# plan_provided_input_extract <plan_path> <project_root> <state_root> [explicit_task]
#
# Pure extractor for an operator-supplied leaf Ralph plan. Never writes files and
# never mutates checkboxes. Prints one JSON object to stdout with:
#   schemaVersion, sourceKind, originalPath, originalSha256, format,
#   totalTodos, completedTodos, openTodos, overview, headerRuntime, headerModel,
#   task, taskProvenance
# Rejects workflows, graph/orchestration shapes, zero-TODO / zero-open plans,
# invalid checkbox or YAML routing, unsupported formats, and symlink-resolved
# paths outside the four allowed roots.
plan_provided_input_extract() {
  local plan_path="$1"
  local project_root="$2"
  local state_root="$3"
  local explicit_task="${4:-}"

  if [[ -z "$plan_path" || -z "$project_root" || -z "$state_root" ]]; then
    echo "Error: plan_provided_input_extract requires <plan_path> <project_root> <state_root> [explicit_task]" >&2
    return 1
  fi
  if [[ ! -f "$plan_path" ]]; then
    echo "Error: provided plan not found: $plan_path" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: plan_provided_input_extract requires python3" >&2
    return 1
  fi

  local plan_abs plan_real
  if [[ "$plan_path" = /* ]]; then
    plan_abs="$plan_path"
  else
    plan_abs="$(pwd -P)/$plan_path"
  fi
  plan_real="$(plan_provided_input_realpath "$plan_abs")" || {
    echo "Error: cannot resolve provided plan path: $plan_path" >&2
    return 1
  }

  if ! plan_provided_input_under_allowed_roots "$plan_real" "$project_root" "$state_root"; then
    echo "Error: provided plan must be under the project root, state root, \$HOME/.cursor/plans, or \$HOME/.claude/plans" >&2
    return 1
  fi

  local shape
  shape="$(plan_provided_input_shape "$plan_real")"
  case "$shape" in
    workflow|graph|orchestration)
      echo "Error: unsupported plan for provided input ($shape); supply a classic or YAML Ralph leaf plan" >&2
      return 1
      ;;
    missing)
      echo "Error: provided plan not found: $plan_path" >&2
      return 1
      ;;
    leaf) ;;
    *)
      echo "Error: unsupported plan format for provided input" >&2
      return 1
      ;;
  esac

  local detect_fmt manifest_fmt
  detect_fmt="$(plan_detect_format "$plan_real")" || {
    echo "Error: unsupported plan format for provided input" >&2
    return 1
  }
  if plan_format_is_yaml "$detect_fmt"; then
    manifest_fmt="yaml"
    if ! plan_pipeline_validate_plan "$plan_real"; then
      echo "Error: provided plan has invalid YAML routing" >&2
      return 1
    fi
  elif [[ "$detect_fmt" == "default" ]]; then
    manifest_fmt="classic"
    if plan_provided_input_has_invalid_checkbox_only "$plan_real"; then
      echo "Error: provided plan has invalid checkbox routing (use '- [ ]' / '- [x]', not '- []')" >&2
      return 1
    fi
  else
    echo "Error: unsupported plan format for provided input: $detect_fmt" >&2
    return 1
  fi

  local counts done_n total open_n
  counts="$(count_todos "$plan_real")" || {
    echo "Error: cannot count TODOs in provided plan" >&2
    return 1
  }
  done_n="${counts%% *}"
  total="${counts##* }"
  open_n=$((total - done_n))

  if [[ "${total:-0}" -lt 1 ]]; then
    echo "Error: provided plan has no TODOs" >&2
    return 1
  fi
  if [[ "${open_n:-0}" -lt 1 ]]; then
    echo "Error: provided plan has no pending TODOs" >&2
    return 1
  fi

  local overview header_runtime header_model
  overview="$(plan_provided_input_fm_scalar "$plan_real" "overview")"
  header_runtime="$(plan_provided_input_fm_scalar "$plan_real" "runtime")"
  header_model="$(plan_provided_input_fm_scalar "$plan_real" "model")"

  if [[ -n "$header_runtime" ]]; then
    case "$header_runtime" in
      cursor|claude|codex|opencode|antigravity|agy) ;;
      *)
        echo "Error: provided plan has invalid YAML routing: runtime '$header_runtime'" >&2
        return 1
        ;;
    esac
    if [[ "$header_runtime" == "agy" ]]; then
      header_runtime="antigravity"
    fi
  fi

  local task task_provenance
  if [[ -n "${explicit_task//[[:space:]]/}" ]]; then
    task="$explicit_task"
    task_provenance="explicit"
  elif [[ -n "${overview//[[:space:]]/}" ]]; then
    task="$overview"
    task_provenance="plan-overview"
  else
    task="$(basename -- "$plan_real")"
    task="${task%.md}"
    task="${task%.plan}"
    task_provenance="plan-filename"
  fi

  local original_sha
  original_sha="$(plan_provided_input_file_sha256 "$plan_real")" || return 1

  python3 - "$plan_real" "$original_sha" "$manifest_fmt" \
    "$total" "$done_n" "$open_n" "$overview" "$header_runtime" "$header_model" \
    "$task" "$task_provenance" <<'PY'
import json, sys
(
    original_path,
    original_sha,
    fmt,
    total,
    completed,
    open_n,
    overview,
    header_runtime,
    header_model,
    task,
    task_provenance,
) = sys.argv[1:12]
print(json.dumps({
    "schemaVersion": 1,
    "sourceKind": "provided",
    "originalPath": original_path,
    "originalSha256": original_sha,
    "format": fmt,
    "totalTodos": int(total),
    "completedTodos": int(completed),
    "openTodos": int(open_n),
    "overview": overview,
    "headerRuntime": header_runtime,
    "headerModel": header_model,
    "task": task,
    "taskProvenance": task_provenance,
}, separators=(",", ":")))
PY
}

# plan_provided_input_manifest_json <extract_json> <copied_abs_path> [created_at] [copied_sha256]
#
# Pure transform: builds a schema-valid version-1 input manifest from an extract
# object plus the intended frozen copy path. When copied_sha256 is omitted it
# defaults to originalSha256 (pure byte-copy contract). Does not write files.
plan_provided_input_manifest_json() {
  local extract_json="$1"
  local copied_path="$2"
  local created_at="${3:-}"
  local copied_sha="${4:-}"

  if [[ -z "$extract_json" || -z "$copied_path" ]]; then
    echo "Error: plan_provided_input_manifest_json requires <extract_json> <copied_abs_path> [created_at] [copied_sha256]" >&2
    return 1
  fi
  if [[ "$copied_path" != /* ]]; then
    echo "Error: copied path must be absolute: $copied_path" >&2
    return 1
  fi
  if [[ -z "$created_at" ]]; then
    created_at="$(plan_provided_input_utc_now)" || return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: plan_provided_input_manifest_json requires python3" >&2
    return 1
  fi

  python3 - "$extract_json" "$copied_path" "$created_at" "$copied_sha" <<'PY'
import json, re, sys
extract = json.loads(sys.argv[1])
copied_path = sys.argv[2]
created_at = sys.argv[3]
copied_sha_arg = sys.argv[4]
sha = extract.get("originalSha256", "")
copied_sha = copied_sha_arg or sha
if not re.fullmatch(r"[a-f0-9]{64}", copied_sha or ""):
    print("Error: copiedSha256 must be 64 lowercase hex chars", file=sys.stderr)
    raise SystemExit(1)
required = (
    "schemaVersion", "sourceKind", "originalPath", "originalSha256",
    "format", "totalTodos", "completedTodos", "openTodos", "task", "taskProvenance",
)
missing = [k for k in required if k not in extract]
if missing:
    print(f"Error: extract missing fields: {', '.join(missing)}", file=sys.stderr)
    raise SystemExit(1)
manifest = {
    "schemaVersion": int(extract["schemaVersion"]),
    "sourceKind": extract["sourceKind"],
    "originalPath": extract["originalPath"],
    "copiedPath": copied_path,
    "originalSha256": sha,
    "copiedSha256": copied_sha,
    "format": extract["format"],
    "totalTodos": int(extract["totalTodos"]),
    "completedTodos": int(extract["completedTodos"]),
    "openTodos": int(extract["openTodos"]),
    "task": extract["task"],
    "taskProvenance": extract["taskProvenance"],
    "createdAt": created_at,
}
print(json.dumps(manifest, separators=(",", ":")))
PY
}

# plan_provided_input_to_run_metadata <manifest_json> <manifest_abs_path>
#
# Pure transform: maps a version-1 input manifest into the closed run.json
# inputPlan object (sourcePath = copiedPath, sha256 = copiedSha256).
plan_provided_input_to_run_metadata() {
  local manifest_json="$1"
  local manifest_path="$2"

  if [[ -z "$manifest_json" || -z "$manifest_path" ]]; then
    echo "Error: plan_provided_input_to_run_metadata requires <manifest_json> <manifest_abs_path>" >&2
    return 1
  fi
  if [[ "$manifest_path" != /* ]]; then
    echo "Error: manifest path must be absolute: $manifest_path" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: plan_provided_input_to_run_metadata requires python3" >&2
    return 1
  fi

  python3 - "$manifest_json" "$manifest_path" <<'PY'
import json, re, sys
manifest = json.loads(sys.argv[1])
manifest_path = sys.argv[2]
required = (
    "originalPath", "copiedPath", "copiedSha256", "format",
    "totalTodos", "completedTodos", "openTodos",
)
missing = [k for k in required if k not in manifest]
if missing:
    print(f"Error: manifest missing fields: {', '.join(missing)}", file=sys.stderr)
    raise SystemExit(1)
sha = manifest["copiedSha256"]
if not re.fullmatch(r"[a-f0-9]{64}", sha or ""):
    print("Error: copiedSha256 must be 64 lowercase hex chars", file=sys.stderr)
    raise SystemExit(1)
for key in ("originalPath", "copiedPath"):
    if not str(manifest[key]).startswith("/"):
        print(f"Error: {key} must be absolute", file=sys.stderr)
        raise SystemExit(1)
print(json.dumps({
    "originalPath": manifest["originalPath"],
    "sourcePath": manifest["copiedPath"],
    "manifestPath": manifest_path,
    "sha256": sha,
    "format": manifest["format"],
    "totalTodos": int(manifest["totalTodos"]),
    "completedTodos": int(manifest["completedTodos"]),
    "openTodos": int(manifest["openTodos"]),
}, separators=(",", ":")))
PY
}

# plan_provided_input_validate_manifest <manifest_json_file>
# Validate a written (or staged) manifest against workflow-input-plan.schema.json.
plan_provided_input_validate_manifest() {
  local manifest_path="$1"
  local schema_path py
  if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
    echo "Error: plan_provided_input_validate_manifest requires an existing manifest file" >&2
    return 1
  fi
  schema_path="$(plan_provided_input_schema_path)"
  if [[ ! -f "$schema_path" ]]; then
    echo "Error: missing schema: $schema_path" >&2
    return 1
  fi
  py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../python/artifact_json_schema.py"
  if [[ ! -f "$py" ]]; then
    echo "Error: missing artifact_json_schema.py" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: plan_provided_input_validate_manifest requires python3" >&2
    return 1
  fi
  python3 "$py" validate-final-output --schema "$schema_path" --artifact "$manifest_path"
}
