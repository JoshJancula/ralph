# Codex agents

This directory is the home for **Codex agent definitions** under `bundle/.codex/agents/`.

Ralph no longer generates the six built-in profiles (`research`, `architect`,
`implementation`, `code-review`, `qa`, `security`) into runtime directories.
Instruction roles ship under the shared `.ralph/roles/` path instead, and
`scripts/sync-runtime-assets.sh` leaves anything here untouched.

Put your own native agents here. Ralph does not create, rewrite, or remove them.
For the `config.json` schema Ralph tooling validates against, see
[`../../.cursor/agents/README.md`](../../.cursor/agents/README.md).
