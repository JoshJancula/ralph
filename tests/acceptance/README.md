# Real-runtime acceptance harnesses

These harnesses invoke authenticated provider CLIs against disposable graph
fixtures. They can consume LLM credits and are deliberately excluded from CI
and `bash scripts/run-bats.sh`.

Each script refuses to run unless its command includes the exact opt-in flag:

```bash
bash tests/acceptance/accept-cross-runtime-real-cli.sh --run-real-runtime-acceptance
bash tests/acceptance/accept-parallel-implementation-real-cli.sh --run-real-runtime-acceptance
```

Run one only when you intentionally want to verify real provider behavior and
have reviewed the required installed runtimes and configured credentials.

## Claude native context without paid requests

This separate harness runs the installed Claude CLI through Ralph's invocation
helper against a localhost fake Anthropic API. It uses disposable personal and
project configuration, requires no credentials, and makes no paid model calls:

```bash
python3 tests/acceptance/accept-claude-native-context.py --run-local-cli-acceptance
```

It verifies personal/project memory and rules, project imports in the same
workspace, actual invocation of personal/project skills, additive Ralph
instructions, and unchanged operator files. Cases cover native mode and separate
agent workspaces in raw and hybrid modes. Claude's own external-import approvals
still apply in a separate workspace. The test requires permission to bind a
localhost socket and launch the installed CLI; it is excluded from CI and Bats.
