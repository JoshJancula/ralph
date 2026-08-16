#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

DOC="$REPO_ROOT/plugins/ralph-orchestrator/README.md"

@test "operator guide covers the beta journey and consent boundary" {
  [ -f "$DOC" ]
  grep -q '0.1.0-beta.1' "$DOC"
  grep -q 'git clone' "$DOC"
  grep -q 'ralph-status' "$DOC"
  grep -q 'Compatibility remediation' "$DOC"
  grep -q 'confirmationId' "$DOC"
  grep -q 'legacy Ralph setup' "$DOC"
  grep -q 'Supported host versions' "$DOC"
  grep -q 'non-TTY' "$DOC"
  grep -q 'Troubleshooting' "$DOC"
  grep -q 'Installation consent authorizes only installation' "$DOC"
  grep -q 'second Ralph execution engine' "$DOC"
  ! grep -Eiq '(is|as|release)[[:space:]]+GA|generally available|general availability' "$DOC"
}

@test "operator guide uses existing CLI surface and documents every consent form" {
  grep -q 'ralph --bundle-path' "$DOC"
  grep -q 'ralph run --plan' "$DOC"
  grep -q 'ralph setup --runtime' "$DOC"
  grep -q -- '--confirmation-id' "$DOC"
  grep -q -- '--request' "$DOC"
  grep -q -- '--yes' "$DOC"
  grep -q 'real operator' "$DOC"
  grep -q 'full confirmation id' "$DOC"
  grep -q 'Piped input' "$DOC"

  # These are not Ralph CLI verbs. Workflow names may use doctor, but the
  # guide must not present these names as commands.
  ! grep -Eq '`ralph (doctor|capabilities|validate|hook)([[:space:]]|`)' "$DOC"
  ! grep -Eq 'ralph (status|agents)([[:space:]]|`)' "$DOC"

  # The package delegates to the installed CLI and must not claim to ship one.
  ! grep -Eiq '(bundled|vendor(ed)?|included|ships)[[:space:]]+(a[[:space:]]+)?(second[[:space:]]+)?Ralph[[:space:]]+engine' "$DOC"
}

@test "all relative documentation links resolve" {
  python3 - "$DOC" <<'PY'
import pathlib
import re
import sys

doc = pathlib.Path(sys.argv[1])
text = doc.read_text(encoding="utf-8")
for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
    target = target.split("#", 1)[0]
    if not target or "://" in target or target.startswith("mailto:"):
        continue
    path = (doc.parent / target).resolve()
    if not path.exists():
        raise SystemExit(f"missing documentation link: {target}")
PY
}
