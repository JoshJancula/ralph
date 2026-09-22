/**
 * Orchestrates one assistant turn.
 *
 * The flow is seed -> loop -> propose:
 *
 * 1. A small, fixed set of cheap reads is seeded into the prompt so ordinary
 *    "what do I have?" questions cost zero extra CLI spawns.
 * 2. The agent loop (agent-loop.ts) lets the model request any other read or
 *    draft tool it needs, bounded to a few rounds.
 * 3. Anything that would change state comes back as a proposal, which this
 *    service enriches with a real preview — cron fire times from the actual
 *    cron engine, workflow validation from the actual codec — before the UI
 *    renders it as a confirm card. Nothing mutates until the user confirms,
 *    and the confirmation is committed through the existing guarded REST
 *    routes, not from here.
 *
 * The pre-existing `approvedAction` path is kept: it executes exactly the one
 * { tool, arguments } object the UI sent, never anything inferred from text.
 */
import { runAgentLoop, type AssistantProposal } from './agent-loop';
import {
  ASSISTANT_TOOLS,
  SEED_TOOL_NAMES,
  findAssistantTool,
  type AssistantToolName,
} from './tools';
import type {
  AssistantCompletionPort,
  AssistantMessage,
  AssistantToolCall,
  AssistantToolExecutorPort,
  AssistantToolResult,
} from './ports';

export class AssistantValidationError extends Error {}

export interface AssistantDependencies {
  readonly tools: AssistantToolExecutorPort;
  readonly completion: AssistantCompletionPort;
}

export interface AssistantApprovedAction {
  readonly tool: AssistantToolName;
  readonly arguments: Readonly<Record<string, unknown>>;
}

export interface AssistantChatCommand {
  readonly messages: readonly AssistantMessage[];
  readonly pageContext?: string;
  /** The one mutating tool call the UI's confirm card sent, or none. Never inferred from message text. */
  readonly approvedAction?: AssistantApprovedAction;
  readonly preferredRuntime?: string;
  readonly model?: string;
  readonly signal?: AbortSignal;
}

/** A proposal plus whatever the server could verify about it up front. */
export interface AssistantProposalView {
  readonly id: string;
  readonly tool: AssistantToolName;
  readonly title: string;
  readonly description: string;
  readonly arguments: Readonly<Record<string, unknown>>;
  readonly preview?: unknown;
}

export interface AssistantChatReply {
  readonly role: 'assistant';
  readonly content: string;
  readonly toolsUsed: readonly AssistantToolName[];
  readonly proposals: readonly AssistantProposalView[];
  readonly answeredBy: string;
  readonly degraded: boolean;
}

const MAX_MESSAGES = 40;
const DEFAULT_MAX_ROUNDS = 3;

/** Each round is a cold CLI spawn that re-sends the whole conversation, so the cap stays small. */
function maxRounds(): number {
  const raw = Number(process.env['RALPH_DASHBOARD_ASSISTANT_MAX_ROUNDS']);
  return Number.isFinite(raw) && raw >= 1 ? Math.min(Math.floor(raw), 6) : DEFAULT_MAX_ROUNDS;
}

export class AssistantService {
  constructor(private readonly dependencies: AssistantDependencies) {}

  async chat(command: AssistantChatCommand): Promise<AssistantChatReply> {
    const messages = command.messages.filter((message) => message.content.trim().length > 0);
    if (messages.length === 0) {
      throw new AssistantValidationError('A message is required');
    }
    if (messages.length > MAX_MESSAGES) {
      throw new AssistantValidationError(`Conversation is too long (max ${MAX_MESSAGES} messages)`);
    }

    const seed = await this.readSeed();
    const approved = await this.runApprovedAction(command.approvedAction);
    const seeded = [...seed.map((entry) => entry.name), ...approved.map((entry) => entry.name)];

    const available = await this.dependencies.completion.isAvailable();
    if (!available) {
      return this.degradedReply(seeded, seed, approved, 'no agent runtime installed');
    }

    try {
      const outcome = await runAgentLoop(this.dependencies, {
        systemPrompt: buildSystemPrompt(command.pageContext),
        messages,
        seedContext: renderContext([...seed, ...approved]),
        maxRounds: maxRounds(),
        ...(command.preferredRuntime ? { preferredRuntime: command.preferredRuntime } : {}),
        ...(command.model ? { model: command.model } : {}),
        ...(command.signal ? { signal: command.signal } : {}),
      });
      return {
        role: 'assistant',
        content: outcome.content,
        toolsUsed: [...seeded, ...outcome.toolsUsed],
        proposals: await this.enrichProposals(outcome.proposals),
        answeredBy: outcome.answeredBy,
        degraded: false,
      };
    } catch (error: unknown) {
      // The seed reads already succeeded; a runtime that is on PATH and still
      // refuses (unauthenticated, rate limited) is not a reason to fail the
      // whole request.
      return this.degradedReply(seeded, seed, approved, error instanceof Error ? error.message : 'agent runtime failed');
    }
  }

  /**
   * Attaches a verified preview to each proposal so the confirm card shows
   * facts from the real engine rather than the model's claim about them.
   */
  private async enrichProposals(proposals: readonly AssistantProposal[]): Promise<readonly AssistantProposalView[]> {
    const views: AssistantProposalView[] = [];
    for (const proposal of proposals) {
      const tool = findAssistantTool(proposal.tool);
      views.push({
        id: proposal.id,
        tool: proposal.tool,
        title: describeProposal(proposal),
        description: tool?.description ?? '',
        arguments: proposal.arguments,
        ...(await this.previewFor(proposal)),
      });
    }
    return views;
  }

  private async previewFor(proposal: AssistantProposal): Promise<{ preview?: unknown }> {
    const args = proposal.arguments;
    if (proposal.tool === 'create_schedule' || proposal.tool === 'update_schedule') {
      if (typeof args['cron'] !== 'string' || typeof args['timezone'] !== 'string') {
        return {};
      }
      return { preview: await this.safeExecute({ name: 'preview_cron', arguments: { cron: args['cron'], timezone: args['timezone'] } }) };
    }
    if (proposal.tool === 'create_workflow' && args['model'] && typeof args['model'] === 'object') {
      return { preview: await this.safeExecute({ name: 'validate_workflow_draft', arguments: { model: args['model'] } }) };
    }
    return {};
  }

  private degradedReply(
    used: readonly AssistantToolName[],
    seed: readonly AssistantToolResult[],
    approved: readonly AssistantToolResult[],
    reason: string,
  ): AssistantChatReply {
    return {
      role: 'assistant',
      content: describeWithoutAgent(seed, approved, reason),
      toolsUsed: used,
      proposals: [],
      answeredBy: `dashboard (${reason})`,
      degraded: true,
    };
  }

  /** Reads the cheap always-useful tools. Failures degrade to an error note per tool, never throw. */
  private async readSeed(): Promise<readonly AssistantToolResult[]> {
    const results: AssistantToolResult[] = [];
    for (const name of SEED_TOOL_NAMES) {
      results.push({ name, result: await this.safeExecute({ name, arguments: {} }) });
    }
    return results;
  }

  private async runApprovedAction(approvedAction: AssistantApprovedAction | undefined): Promise<readonly AssistantToolResult[]> {
    if (!approvedAction) {
      return [];
    }
    const tool = findAssistantTool(approvedAction.tool);
    if (!tool) {
      throw new AssistantValidationError(`Unknown assistant tool: ${approvedAction.tool}`);
    }
    if (tool.kind !== 'propose') {
      // Read tools run in the loop anyway; approving one is harmless but pointless.
      return [];
    }
    for (const parameter of tool.parameters) {
      if (parameter.required && !approvedAction.arguments[parameter.name]) {
        throw new AssistantValidationError(`"${parameter.name}" is required for ${tool.name}`);
      }
    }
    const result = await this.safeExecute({ name: approvedAction.tool, arguments: approvedAction.arguments });
    return [{ name: approvedAction.tool, result }];
  }

  private async safeExecute(call: AssistantToolCall): Promise<unknown> {
    try {
      return await this.dependencies.tools.execute(call);
    } catch (error: unknown) {
      return { error: error instanceof Error ? error.message : 'tool failed' };
    }
  }
}

function describeProposal(proposal: AssistantProposal): string {
  const args = proposal.arguments;
  const text = (key: string): string => (typeof args[key] === 'string' ? (args[key] as string) : '');
  switch (proposal.tool) {
    case 'create_task':
      return `Create task: ${text('title')}`;
    case 'create_tasks':
      return `Create ${Array.isArray(args['tasks']) ? (args['tasks'] as unknown[]).length : 0} tasks`;
    case 'update_task':
      return `Update task ${text('id')}`;
    case 'launch_task':
      return `Launch task ${text('id')}`;
    case 'create_workflow':
      return `Create workflow ${text('id')} (${text('scope')})`;
    case 'create_schedule':
      return `Create schedule: ${text('name')}`;
    case 'update_schedule':
      return `Update schedule ${text('id')}`;
    case 'start_workflow':
      return `Start workflow ${text('workflowId')}`;
    case 'cancel_run':
      return `Cancel run ${text('runId')}`;
    default:
      return proposal.tool;
  }
}

function renderToolManifest(): string {
  return ASSISTANT_TOOLS.map((tool) => {
    const params = tool.parameters.length
      ? tool.parameters.map((p) => `${p.name}${p.required ? '' : '?'}: ${p.type}`).join(', ')
      : '(no arguments)';
    return `- [${tool.kind}] ${tool.name}(${params}) — ${tool.description}`;
  }).join('\n');
}

export function buildSystemPrompt(pageContext?: string): string {
  return [
    'You are the assistant built into the Ralph dashboard, a local tool for building and running Ralph workflows, tasks, and schedules.',
    '',
    'You can call tools. To call one, emit a fenced block tagged `ralph` containing JSON:',
    '',
    '```ralph',
    '{"tool": "get_run_status", "arguments": {"runId": "run-..."}}',
    '```',
    '',
    'Emit only the block and no other prose when you are calling a tool. You may put several calls in one block as a JSON array.',
    '',
    'Tool kinds and what they mean for you:',
    '- read: returns live state. Call these whenever the SYSTEM STATE below does not already answer the question.',
    '- draft: checks your own work without changing anything. Use them before you propose.',
    '- propose: asks the user to confirm a change. Proposing ends your turn and the dashboard shows a confirm card.',
    '',
    'Rules you must follow:',
    '- Never claim you created, started, scheduled, or cancelled anything. A propose call only asks; the user decides.',
    '- Before create_schedule or update_schedule, call preview_cron and check the returned times really match what the user asked for. Fix the cron and check again if they do not.',
    '- Before create_workflow, call validate_workflow_draft and fix every reported issue until it returns valid: true.',
    '- Prefer an existing workflow or template over inventing a new one; call list_workflow_templates and list_workflows first.',
    '- A proposed task status must be one of the columns list_task_statuses returns.',
    '- When breaking work down, use create_tasks once with all the items rather than many single proposals.',
    '- Answer from live state only. Never invent workflows, runs, plans, tasks, or schedules that the tools did not return.',
    '- Be concise and concrete. Name the exact workflow, run, task, or schedule.',
    '',
    'Available tools:',
    renderToolManifest(),
    pageContext ? `\nThe user is currently on: ${pageContext}.` : '',
  ]
    .filter((line) => line !== null && line !== undefined)
    .join('\n');
}

export function renderContext(results: readonly AssistantToolResult[]): string {
  const body = results.map((entry) => `## ${entry.name}\n${safeStringify(entry.result)}`).join('\n\n');
  return `SYSTEM STATE (live, read at the time of this message)\n\n${body}`;
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2) ?? 'null';
  } catch {
    return '"<unserializable>"';
  }
}

/** What the assistant says when no agent runtime answers in prose. It still ran the seed reads, so it reports what it found. */
export function describeWithoutAgent(
  seed: readonly AssistantToolResult[],
  approved: readonly AssistantToolResult[],
  reason = 'no agent runtime installed',
): string {
  const lines = [`I could not reach an agent to answer in prose (${reason}), so here is the live state I read for you instead.`, ''];
  for (const entry of [...seed, ...approved]) {
    lines.push(`## ${entry.name}`);
    lines.push(safeStringify(entry.result));
    lines.push('');
  }
  return lines.join('\n');
}
