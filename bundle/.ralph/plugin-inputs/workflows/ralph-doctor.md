---
name: ralph-doctor
description: Diagnose Ralph bundle, workflow, and runtime configuration state without installation or execution.
---

# ralph-doctor

Read-only Ralph plugin workflow. Diagnoses CLI presence and plugin ABI
compatibility. Does not install software or execute a plan.

Category: read-only (P09). Allowed operations: probe, inspect, print
remediation. The only bootstrap operation is `probe`. Never call `ensure`,
never run `install.sh`, and never call `ralph-plugin-exec.sh`.

`ralph-doctor` is a plugin workflow name, not a CLI verb. There is no
`ralph doctor` subcommand. Compose diagnostics from verbs that exist today:
`ralph --bundle-path`, `ralph workflow runs`, and `ralph workflow list`, plus
direct inspection of runtime config directories. Never invoke `ralph run`,
`ralph workflow start`, or `ralph workflow resume`.

```bash
set -euo pipefail

_rel="{{SHARED_BOOTSTRAP_REL}}"
if [[ "$_rel" == /* ]]; then
  BOOTSTRAP="$_rel"
else
  BOOTSTRAP="${RALPH_PLUGIN_ROOT:-.}/$_rel"
fi

project="${RALPH_PLUGIN_PROJECT_ROOT:-.}"

probe_ec=0
probe_json=""
probe_json="$(/bin/bash "$BOOTSTRAP" probe --json)" || probe_ec=$?
printf '%s\n' "$probe_json"

outcome="$(printf '%s\n' "$probe_json" | jq -r '.outcome // empty')"
remediation="$(printf '%s\n' "$probe_json" | jq -r '.remediation // empty')"

printf 'workflow: ralph-doctor\n'
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

printf 'inspect: ralph --bundle-path\n'
ralph --bundle-path || true

printf 'inspect: ralph workflow runs\n'
ralph workflow runs --all || true

printf 'inspect: ralph workflow list\n'
ralph workflow list || true

printf 'inspect: runtime config directories\n'
for d in .claude .cursor .codex .opencode .agents; do
  if [[ -d "$project/$d" ]]; then
    printf 'runtime-config: %s present\n' "$d"
  else
    printf 'runtime-config: %s absent\n' "$d"
  fi
done

exit 0
```
