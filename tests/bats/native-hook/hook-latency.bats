#!/usr/bin/env bats
# Smoke: scripts/hook-latency.sh emits a markdown table row per Hook inventory entry.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SCRIPT="$REPO_ROOT/scripts/hook-latency.sh"
HOOKS_DOC="$REPO_ROOT/docs/HOOKS.md"

setup() {
  _tmp="$(mktemp -d)"
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
}

_inventory_hooks() {
  HOOKS_DOC="$HOOKS_DOC" python3 - <<'PY'
import os, re
doc = open(os.environ["HOOKS_DOC"], encoding="utf-8").read()
m = re.search(r"## Hook inventory\n(.*?)(?=\n## )", doc, re.S)
assert m, "hook inventory missing"
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
}

@test "hook-latency.sh N=1 prints a table row per inventory hook" {
  [[ -f "$SCRIPT" ]]
  [[ -f "$HOOKS_DOC" ]]

  local out hooks_file hook
  out="$_tmp/latency.md"
  hooks_file="$_tmp/hooks.txt"

  run bash "$SCRIPT" -n 1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$out"

  grep -q 'Hook | unset' "$out" || grep -q '| Hook |' "$out"
  grep -q 'compact-bash-output.sh' "$out"

  _inventory_hooks >"$hooks_file"
  [ "$(wc -l <"$hooks_file" | tr -d ' ')" -ge 10 ]

  while IFS= read -r hook; do
    [[ -n "$hook" ]] || continue
    # Row cells wrap the inventory-relative path in backticks.
    grep -qF "\`$hook\`" "$out"
  done <"$hooks_file"
}
