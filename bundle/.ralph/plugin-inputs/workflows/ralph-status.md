---
name: ralph-status
description: Inspect Ralph CLI and plugin ABI compatibility without installing or executing anything.
---

# ralph-status

Read-only Ralph plugin workflow. Prints CLI and plugin compatibility status.
Does not install software or execute a plan.

Category: read-only (P09). Allowed operations: probe, inspect, print
remediation. The only bootstrap operation is `probe`. Never call `ensure`,
never run `install.sh`, and never call `ralph-plugin-exec.sh`.

Compose status from the shared bootstrap probe, which itself uses existing CLI
verbs (`ralph --help`, `ralph --bundle-path`) and inspects
`plugin-api-version`. Do not invent a `ralph status` or `ralph doctor`
subcommand.

```bash
set -euo pipefail

_rel="{{SHARED_BOOTSTRAP_REL}}"
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

printf 'workflow: ralph-status\n'
printf 'inspect: compatibility probe\n'
if [[ -n "$remediation" ]]; then
  printf 'remediation: %s\n' "$remediation"
fi

case "$outcome" in
  usable)
    printf 'status: healthy\n'
    exit 0
    ;;
  newer)
    printf 'status: newer-cli-warning\n'
    exit 0
    ;;
  *)
    printf 'status: blocked\n'
    if [[ "$probe_ec" -ne 0 ]]; then
      exit "$probe_ec"
    fi
    exit 1
    ;;
esac
```
