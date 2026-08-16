<!-- GENERATED from bundle/.ralph/plugin-inputs/workflows/ralph-graph.md by scripts/sync-plugin-assets.sh - edit the canonical file -->
---
name: ralph-graph
description: Scaffold, edit, validate, compile, and render Ralph graph plans without running them.
---

# ralph-graph

Authoring Ralph plugin workflow. Scaffolds, edits, validates, compiles, and
renders graph plans. Does not run or resume a graph.

Category: authoring (P09). Allowed operations: scaffold, edit, validate,
compile, render. The only bootstrap operation is `probe`. Never call
`ensure`, never run `install.sh`, and never call `ralph-plugin-exec.sh`.
Never invoke `ralph run`, `ralph graph run`, or `ralph graph resume`.

Before assigning any runtime or model, source and call
`graph_runtime_capabilities` from
`<bundle>/bash-lib/graph/graph-runtime-capabilities.sh`. There is no
`ralph capabilities` verb. Do not invent a model. Offer only runtimes the
inventory plus a present CLI can establish. If no enumerated model list can
be established, ask the operator instead of proposing a name.

Node dependencies are derived from declared `requires` and `produces`
artifacts and from nothing else. An undeclared dependency will run in
parallel rather than in order. Prompt for artifact declarations as part of
authoring.

```bash
set -euo pipefail

_rel="../shared/ralph-plugin-bootstrap.sh"
if [[ "$_rel" == /* ]]; then
  BOOTSTRAP="$_rel"
else
  BOOTSTRAP="${RALPH_PLUGIN_ROOT:-.}/$_rel"
fi

operation="${RALPH_PLUGIN_OPERATION:-scaffold}"
plan_path="${RALPH_PLUGIN_PLAN_PATH:-}"
plan_name="${RALPH_PLUGIN_PLAN_NAME:-}"
requested_runtime="${RALPH_PLUGIN_RUNTIME:-}"
requested_model="${RALPH_PLUGIN_MODEL:-}"
enumerated_models="${RALPH_PLUGIN_MODELS:-}"

probe_ec=0
probe_json=""
probe_json="$(/bin/bash "$BOOTSTRAP" probe --json)" || probe_ec=$?
printf '%s\n' "$probe_json"

outcome="$(printf '%s\n' "$probe_json" | jq -r '.outcome // empty')"
remediation="$(printf '%s\n' "$probe_json" | jq -r '.remediation // empty')"
bundle_path="$(printf '%s\n' "$probe_json" | jq -r '.bundlePath // empty')"

printf 'workflow: ralph-graph\n'
printf 'category: authoring\n'
if [[ -n "$remediation" ]]; then
  printf 'remediation: %s\n' "$remediation"
fi

case "$outcome" in
  usable|newer)
    ;;
  *)
    printf 'status: blocked\n'
    if [[ "$probe_ec" -ne 0 ]]; then
      exit "$probe_ec"
    fi
    exit 1
    ;;
esac

if [[ "$outcome" == "newer" ]]; then
  printf 'status: newer-cli-warning\n'
else
  printf 'status: healthy\n'
fi

case "$operation" in
  run|resume|execute|preview)
    printf 'rejected-operation: %s\n' "$operation"
    printf 'reason: authoring workflows never execute\n'
    exit 1
    ;;
  scaffold|edit|validate|compile|render)
    ;;
  *)
    printf 'rejected-operation: %s\n' "$operation"
    printf 'reason: allowed operations are scaffold, edit, validate, compile, render\n'
    exit 1
    ;;
esac

printf 'operation: %s\n' "$operation"
printf 'artifacts: node dependencies come only from declared requires and produces\n'
printf 'capabilities-query: graph_runtime_capabilities\n'
printf 'model-policy: never-invent\n'

caps_file="$bundle_path/bash-lib/graph/graph-runtime-capabilities.sh"
if [[ ! -f "$caps_file" ]]; then
  printf 'capabilities: missing\n'
  printf 'model-status: ask-operator\n'
  exit 1
fi

# shellcheck source=/dev/null
source "$caps_file"

available_runtimes=()
while IFS= read -r runtime; do
  [[ -n "$runtime" ]] || continue
  caps_json="$(graph_runtime_capabilities "$runtime")"
  usage="$(printf '%s\n' "$caps_json" | jq -r '.usageReliability // "unavailable"')"
  cli="$(graph_runtime_cli_name "$runtime")"
  cli="${cli//$'\n'/}"
  if [[ "$usage" == "unavailable" ]]; then
    continue
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" >/dev/null 2>&1; then
    continue
  fi
  available_runtimes+=("$runtime")
done <<< "${GRAPH_RUNTIME_CAPABILITIES_KNOWN:-}"

printf 'available-runtimes:'
if [[ ${#available_runtimes[@]} -eq 0 ]]; then
  printf ' none\n'
else
  printf ' %s\n' "${available_runtimes[*]}"
fi

runtime_offered=0
if [[ -n "$requested_runtime" ]]; then
  for runtime in "${available_runtimes[@]+"${available_runtimes[@]}"}"; do
    if [[ "$runtime" == "$requested_runtime" ]]; then
      runtime_offered=1
      break
    fi
  done
  if [[ "$runtime_offered" -eq 1 ]]; then
    printf 'assigned-runtime: %s\n' "$requested_runtime"
  else
    printf 'assigned-runtime: none\n'
    printf 'runtime-status: not-offered\n'
  fi
else
  printf 'assigned-runtime: none\n'
fi

model_in_list=0
if [[ -n "$enumerated_models" ]]; then
  printf 'enumerated-models: present\n'
  if [[ -n "$requested_model" ]]; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if [[ "$candidate" == "$requested_model" ]]; then
        model_in_list=1
        break
      fi
    done <<< "$enumerated_models"
  fi
else
  printf 'enumerated-models: absent\n'
fi

if [[ -n "$requested_model" && "$model_in_list" -eq 1 && "$runtime_offered" -eq 1 ]]; then
  printf 'assigned-model: %s\n' "$requested_model"
else
  printf 'assigned-model: none\n'
  printf 'model-status: ask-operator\n'
fi

case "$operation" in
  scaffold)
    printf 'author: ralph create graph\n'
    if [[ -n "$plan_name" ]]; then
      ralph create plan --format graph --name "$plan_name"
    else
      ralph create graph
    fi
    ;;
  edit)
    if [[ -z "$plan_path" ]]; then
      printf 'edit: plan path required\n'
      exit 1
    fi
    printf 'edit: %s\n' "$plan_path"
    printf 'mutate: none\n'
    ;;
  validate)
    if [[ -z "$plan_path" ]]; then
      printf 'validate: plan path required\n'
      exit 1
    fi
    validator="$bundle_path/validate-plan.sh"
    printf 'validate: %s\n' "$plan_path"
    /bin/bash "$validator" "$plan_path"
    ;;
  compile)
    if [[ -z "$plan_path" ]]; then
      printf 'compile: plan path required\n'
      exit 1
    fi
    printf 'author: ralph graph compile\n'
    ralph graph compile "$plan_path"
    ;;
  render)
    if [[ -z "$plan_path" ]]; then
      printf 'render: plan path required\n'
      exit 1
    fi
    printf 'author: ralph graph render\n'
    ralph graph render "$plan_path"
    ;;
esac

printf 'execute: never\n'
exit 0
```
