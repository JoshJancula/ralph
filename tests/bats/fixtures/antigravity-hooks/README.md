# Antigravity hook fixtures

Sample stdin payloads for the Antigravity (agy) native hooks. They are the single
input source for the antigravity hook bats tests.

- agy version: 1.2.7
- The contract (camelCase protojson keys, `toolCall.name`, `toolCall.args.CommandLine`,
  `workspacePaths[]`, `fullyIdle`, `executionNum`, `terminationReason`) was read from the
  hooks documentation embedded in the agy binary.

Files:

- `pretool-run-command.json`: PreToolUse for the `run_command` tool.
- `pretool-view-file.json`: PreToolUse for a non-shell tool (`view_file`).
- `posttool-ok.json`: PostToolUse without an error.
- `posttool-error.json`: PostToolUse with an `error` field.
- `stop-idle.json`: Stop with `fullyIdle` true.
- `stop-busy.json`: Stop with `fullyIdle` false.

PostToolUse carries no tool output and no duration. These fixtures deliberately use only
agy keys, not the Cursor payload shape.
