/**
 * The assistant's tool surface. Descriptors are data, not code: the same
 * list is sent to the model as its tool manifest, served at
 * GET /api/assistant/tools, and used to validate every call before it
 * reaches an adapter.
 *
 * Tools fall into three kinds, and the kind decides what the server is
 * allowed to do with a call:
 *
 * - `read`   Pure reads of live state. The agent loop runs these freely,
 *            as many rounds as its budget allows.
 * - `draft`  Write-free computation that answers "would this work?" —
 *            cron previews, workflow-draft validation. Safe in the loop
 *            because nothing reaches a workflow scope or the task store;
 *            they are what let the model check its own proposal against
 *            the real codec before a human ever sees it.
 * - `propose` Everything that changes state. These NEVER execute inside
 *            the loop. The service compiles them into proposals the UI
 *            renders as confirm cards, and only an explicit approval
 *            round-trip executes one. This preserves the original
 *            property that a mutation is never inferred from model text.
 */

export type AssistantToolKind = 'read' | 'draft' | 'propose';

export type AssistantToolName =
  // read
  | 'list_workflows'
  | 'get_workflow'
  | 'list_runs'
  | 'get_run_status'
  | 'list_plans'
  | 'list_tasks'
  | 'list_task_statuses'
  | 'list_schedules'
  | 'list_workflow_templates'
  | 'list_runtimes'
  // draft
  | 'preview_cron'
  | 'validate_workflow_draft'
  // propose
  | 'create_task'
  | 'create_tasks'
  | 'update_task'
  | 'launch_task'
  | 'create_workflow'
  | 'create_schedule'
  | 'update_schedule'
  | 'start_workflow'
  | 'cancel_run';

export type AssistantParameterType = 'string' | 'number' | 'boolean' | 'object' | 'array';

export interface AssistantToolParameter {
  readonly name: string;
  readonly description: string;
  readonly required: boolean;
  readonly type: AssistantParameterType;
}

export interface AssistantToolDescriptor {
  readonly name: AssistantToolName;
  readonly description: string;
  readonly parameters: readonly AssistantToolParameter[];
  readonly kind: AssistantToolKind;
}

function p(
  name: string,
  description: string,
  required: boolean,
  type: AssistantParameterType = 'string',
): AssistantToolParameter {
  return { name, description, required, type };
}

export const ASSISTANT_TOOLS: readonly AssistantToolDescriptor[] = [
  // ---------------------------------------------------------------------------
  // read
  // ---------------------------------------------------------------------------
  {
    name: 'list_workflows',
    description: 'List every workflow with its id, scope (project/global/bundled), and overview.',
    parameters: [],
    kind: 'read',
  },
  {
    name: 'get_workflow',
    description:
      'Full detail for one workflow: scope, resolved routing, stage topology, and dependencies. Use this before proposing a run or a schedule so the stages and required inputs are known.',
    parameters: [p('workflowId', 'Workflow id', true)],
    kind: 'read',
  },
  {
    name: 'list_runs',
    description: 'Recent workflow runs with id, workflow, state, and creation time.',
    parameters: [],
    kind: 'read',
  },
  {
    name: 'get_run_status',
    description:
      'Full status for one run: stages, diagnosis, and the operator next action. Use this to explain why a run is stuck or failed.',
    parameters: [p('runId', 'Run id', true)],
    kind: 'read',
  },
  {
    name: 'list_plans',
    description: 'List managed leaf plans under .ralph-workspace/plans/.',
    parameters: [],
    kind: 'read',
  },
  {
    name: 'list_tasks',
    description:
      'Every dashboard task with id, title, status, assigned workflow, target project, and a summary of its most recent attempt.',
    parameters: [],
    kind: 'read',
  },
  {
    name: 'list_task_statuses',
    description:
      'The task board columns for this project, in order. A proposed task status must be one of these.',
    parameters: [],
    kind: 'read',
  },
  {
    name: 'list_schedules',
    description:
      'Every schedule with its cron, timezone, enabled state, workflow or task-worker configuration, and upcoming fire times.',
    parameters: [],
    kind: 'read',
  },
  {
    name: 'list_workflow_templates',
    description:
      'Installable workflow templates with category, purpose, and outputs. Use before proposing a brand-new workflow: an existing template is usually the better answer.',
    parameters: [],
    kind: 'read',
  },
  {
    name: 'list_runtimes',
    description: 'Agent runtimes installed on this machine, for choosing workflow routing defaults.',
    parameters: [],
    kind: 'read',
  },

  // ---------------------------------------------------------------------------
  // draft (write-free; safe to run inside the loop)
  // ---------------------------------------------------------------------------
  {
    name: 'preview_cron',
    description:
      'Check a five-field cron and IANA timezone and return the next fire times. Always call this before proposing a schedule, and revise the cron if the times are not what the user asked for.',
    parameters: [
      p('cron', 'Five-field cron expression, for example "0 9 * * 1-5"', true),
      p('timezone', 'IANA timezone, for example "America/New_York"', true),
    ],
    kind: 'draft',
  },
  {
    name: 'validate_workflow_draft',
    description:
      'Validate a workflow model against the real Ralph codec without writing anything, returning errors and the emitted frontmatter. Always call this before proposing create_workflow, and fix the reported issues until it is valid.',
    parameters: [
      p('model', 'Workflow model: { name, overview, kind, mode, defaults, pipeline: { stages } }', true, 'object'),
    ],
    kind: 'draft',
  },

  // ---------------------------------------------------------------------------
  // propose (compiled into confirm cards; never executed inside the loop)
  // ---------------------------------------------------------------------------
  {
    name: 'create_task',
    description: 'Propose one new task on the board.',
    parameters: [
      p('title', 'Short imperative title', true),
      p('description', 'What needs doing and why', false),
      p('acceptanceCriteria', 'How a reviewer confirms this is done', false),
      p('workflowId', 'Workflow to run it with, or "auto" to let triage route it', false),
      p('status', 'Board column to create it in; defaults to backlog', false),
      p('scope', '"project" or "global"; defaults to project', false),
    ],
    kind: 'propose',
  },
  {
    name: 'create_tasks',
    description:
      'Propose several tasks at once, for breaking a larger piece of work into board items. Each entry takes the same fields as create_task.',
    parameters: [p('tasks', 'Array of task objects', true, 'array')],
    kind: 'propose',
  },
  {
    name: 'update_task',
    description: 'Propose changes to an existing task, such as moving its status or assigning a workflow.',
    parameters: [
      p('id', 'Task id', true),
      p('title', 'New title', false),
      p('description', 'New description', false),
      p('acceptanceCriteria', 'New acceptance criteria', false),
      p('workflowId', 'New workflow assignment', false),
      p('status', 'New board column', false),
    ],
    kind: 'propose',
  },
  {
    name: 'launch_task',
    description: 'Propose launching a task that is in the ready column right now.',
    parameters: [p('id', 'Task id', true)],
    kind: 'propose',
  },
  {
    name: 'create_workflow',
    description:
      'Propose creating a new workflow file. Call validate_workflow_draft first and propose only a model that validated cleanly.',
    parameters: [
      p('id', 'Workflow id, lowercase words separated by hyphens', true),
      p('scope', '"project" or "global"', true),
      p('model', 'The validated workflow model', true, 'object'),
    ],
    kind: 'propose',
  },
  {
    name: 'create_schedule',
    description:
      'Propose a new schedule. Either set workflowId to run one workflow on a cron, or set worker to drain a task board column. Call preview_cron first.',
    parameters: [
      p('name', 'Human name for the schedule', true),
      p('cron', 'Five-field cron expression', true),
      p('timezone', 'IANA timezone', true),
      p('workflowId', 'Workflow to start each tick; omit when using worker', false),
      p('worker', 'Task worker: { mode: "one"|"all", maxConcurrent, status }', false, 'object'),
      p('brief', 'Fixed instructions for each run', false),
      p('scope', '"project" or "global"; defaults to project', false),
    ],
    kind: 'propose',
  },
  {
    name: 'update_schedule',
    description: 'Propose changes to an existing schedule, such as a new cron or enabling/disabling it.',
    parameters: [
      p('id', 'Schedule id', true),
      p('name', 'New name', false),
      p('cron', 'New cron expression', false),
      p('timezone', 'New IANA timezone', false),
      p('enabled', 'Whether the schedule is active', false, 'boolean'),
      p('worker', 'Replacement task worker configuration', false, 'object'),
    ],
    kind: 'propose',
  },
  {
    name: 'start_workflow',
    description: 'Propose starting a workflow run with a concrete task description.',
    parameters: [
      p('workflowId', 'Workflow id', true),
      p('task', 'Concrete task description for this run', true),
    ],
    kind: 'propose',
  },
  {
    name: 'cancel_run',
    description: 'Propose cancelling a live or nonterminal workflow run.',
    parameters: [p('runId', 'Run id', true)],
    kind: 'propose',
  },
];

export function findAssistantTool(name: string): AssistantToolDescriptor | null {
  return ASSISTANT_TOOLS.find((tool) => tool.name === name) ?? null;
}

export function isMutatingTool(tool: AssistantToolDescriptor): boolean {
  return tool.kind === 'propose';
}

/** Tools the agent loop may execute on its own: everything that cannot change state. */
export const LOOP_TOOL_NAMES: readonly AssistantToolName[] = ASSISTANT_TOOLS.filter(
  (tool) => tool.kind !== 'propose',
).map((tool) => tool.name);

export const PROPOSE_TOOL_NAMES: readonly AssistantToolName[] = ASSISTANT_TOOLS.filter(
  (tool) => tool.kind === 'propose',
).map((tool) => tool.name);

/**
 * The cheap, always-useful reads seeded into the first turn so the model can
 * answer "what do I have?" without spending a loop round. Everything else it
 * must ask for.
 */
export const SEED_TOOL_NAMES: readonly AssistantToolName[] = [
  // Two `ralph` spawns...
  'list_workflows',
  'list_runs',
  // ...plus local JSON reads, which cost nothing.
  'list_tasks',
  'list_schedules',
];

/** Validates a call's arguments against its descriptor. Returns an error string, or null when the call is well formed. */
export function validateToolArguments(
  tool: AssistantToolDescriptor,
  args: Readonly<Record<string, unknown>>,
): string | null {
  for (const parameter of tool.parameters) {
    const value = args[parameter.name];
    if (value === undefined || value === null || value === '') {
      if (parameter.required) {
        return `"${parameter.name}" is required for ${tool.name}`;
      }
      continue;
    }
    if (!matchesType(value, parameter.type)) {
      return `"${parameter.name}" must be a ${parameter.type} for ${tool.name}`;
    }
  }
  return null;
}

function matchesType(value: unknown, type: AssistantParameterType): boolean {
  switch (type) {
    case 'string':
      return typeof value === 'string';
    case 'number':
      return typeof value === 'number' && Number.isFinite(value);
    case 'boolean':
      return typeof value === 'boolean';
    case 'array':
      return Array.isArray(value);
    case 'object':
      return !!value && typeof value === 'object' && !Array.isArray(value);
    default:
      return false;
  }
}
