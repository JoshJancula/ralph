<!-- GENERATED from bundle/.ralph/plugin-inputs/workflows/ralph-orchestrate.md by scripts/sync-plugin-assets.sh - edit the canonical file -->
---
name: ralph-orchestrate
description: Scaffold, edit, and validate Ralph orchestration plans without executing them.
---

# ralph-orchestrate

Authoring Ralph plugin workflow. Scaffolds, edits, and validates orchestration
plans. Does not execute an orchestration run.

Category: authoring (P09). Allowed operations: scaffold, edit, validate,
compile, render. Compile and render belong to graph authoring; this workflow
does not invoke them. The only bootstrap operation is `probe`. Never call
`ensure`, never run `install.sh`, and never call `ralph-plugin-exec.sh`.
Never invoke `ralph run`, `ralph graph run`, `ralph graph resume`, or the
orchestrator.

Compose authoring from the existing `ralph create orc` verb and
`validate-plan.sh` from the installed bundle. Prompt for `requires` /
`produces` artifact declarations as part of authoring. Do not invent a
`ralph validate` verb.

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

probe_ec=0
probe_json=""
probe_json="$(/bin/bash "$BOOTSTRAP" probe --json)" || probe_ec=$?
printf '%s\n' "$probe_json"

outcome="$(printf '%s\n' "$probe_json" | jq -r '.outcome // empty')"
remediation="$(printf '%s\n' "$probe_json" | jq -r '.remediation // empty')"
bundle_path="$(printf '%s\n' "$probe_json" | jq -r '.bundlePath // empty')"

printf 'workflow: ralph-orchestrate\n'
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
  scaffold|edit|validate)
    ;;
  compile|render)
    printf 'rejected-operation: %s\n' "$operation"
    printf 'reason: compile and render are graph authoring operations\n'
    exit 1
    ;;
  *)
    printf 'rejected-operation: %s\n' "$operation"
    printf 'reason: allowed operations are scaffold, edit, validate\n'
    exit 1
    ;;
esac

printf 'operation: %s\n' "$operation"
printf 'artifacts: declare requires and produces; undeclared dependencies do not serialize\n'

case "$operation" in
  scaffold)
    printf 'author: ralph create orc\n'
    ralph create orc
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
esac

printf 'execute: never\n'
exit 0
```
