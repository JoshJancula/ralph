# Prompt helpers for the MCP server.

generate_next_todo_prompt_definition() {
  jq -n '{
    name: "ralph_run_next_todo_prompt",
    title: "Next unchecked TODO prompt",
    description: "Guides an orchestrator to pick the next unchecked TODO, consult the agent catalog, and describe the following plan invocation.",
    arguments: [
      {
        name: "workspace",
        description: "Absolute workspace path (defaults to the MCP server root).",
        required: false
      },
      {
        name: "plan_path",
        description: "Plan file path relative to the workspace root (e.g., PLAN.md).",
        required: true
      }
    ]
  }'
}

ralph_mcp_build_next_todo_prompt_message() {
  local workspace="$1"
  local plan_path="$2"
  local plan_display="$plan_path"
  if [[ -n "$workspace" && "$plan_display" == "$workspace/"* ]]; then
    plan_display="${plan_display#$workspace/}"
  fi
  cat <<EOF
Next unchecked TODO (plan: $plan_display)

1. Run \`ralph_plan_status\` with workspace=$workspace and plan_path=$plan_display to identify the pending items and the next unchecked TODO.
2. Consult \`resource://ralph/agents\` to understand each agent's responsibilities and runtime capabilities.
3. Decide which runtime and agent should execute the next unchecked TODO, explaining why the chosen agent is a good fit.
4. Provide the upcoming \`ralph_run_plan\` call as JSON (workspace, plan_path, runtime, agent) so the orchestrator can follow your recommendation.

Example invocation:
{
  "name": "ralph_run_plan",
  "arguments": {
    "workspace": "$workspace",
    "plan_path": "$plan_display",
    "runtime": "<chosen-runtime>",
    "agent": "<chosen-agent>"
  }
}

EOF
}
