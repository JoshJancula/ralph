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
