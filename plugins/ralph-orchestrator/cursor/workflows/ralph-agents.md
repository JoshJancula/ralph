<!-- GENERATED from bundle/.ralph/plugin-inputs/workflows/ralph-agents.md by scripts/sync-plugin-assets.sh - edit the canonical file -->
---
name: ralph-agents
description: List and inspect Ralph agent profiles without installing software or executing a plan.
---

# ralph-agents

Read-only Ralph plugin workflow. Lists the six shared agent profiles from
canonical plugin inputs. Does not install software or execute a plan.

Category: read-only (P09). Allowed operations: probe, inspect, print
remediation. The only bootstrap operation is `probe`. Never call `ensure`,
never run `install.sh`, and never call `ralph-plugin-exec.sh`.

Compose the listing from the existing `ralph agent list` verb after a
successful probe. Never call `ralph agent new`, `ralph run`, or any execute
gate. The shared profiles are architect, code-review, implementation, qa,
research, and security.

```bash
set -euo pipefail

_rel="../shared/ralph-plugin-bootstrap.sh"
if [[ "$_rel" == /* ]]; then
  BOOTSTRAP="$_rel"
else
  BOOTSTRAP="${RALPH_PLUGIN_ROOT:-.}/$_rel"
fi

probe_ec=0
probe_json=""
probe_json="$(/bin/bash "$BOOTSTRAP" probe --json)" || probe_ec=$?
printf '%s\n' "$probe_json"

outcome="$(printf '%s\n' "$probe_json" | jq -r '.outcome // empty')"
remediation="$(printf '%s\n' "$probe_json" | jq -r '.remediation // empty')"

printf 'workflow: ralph-agents\n'
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

printf 'inspect: ralph agent list\n'
ralph agent list || true

printf 'shared-agents:\n'
printf 'architect\n'
printf 'code-review\n'
printf 'implementation\n'
printf 'qa\n'
printf 'research\n'
printf 'security\n'

exit 0
```
