/**
 * The assistant's bounded tool-calling loop.
 *
 * The agent runtimes behind `completion.ts` are prose CLIs, not tool-calling
 * APIs, so the protocol is a text one: the model emits a fenced block tagged
 * `ralph` containing a JSON tool call, the server executes it, appends the
 * result, and re-prompts.
 *
 * Two hard rules keep this safe and affordable:
 *
 * 1. Only `read` and `draft` tools run inside the loop. A `propose` call
 *    ends the loop and is returned to the caller as a proposal for the UI
 *    to confirm; the loop never mutates anything.
 * 2. Rounds are capped. Every round is a cold CLI spawn that re-flattens the
 *    whole conversation into a new prompt (see completion.ts), so an
 *    unbounded loop is both slow and expensive. On the last round the model
 *    is told to answer without tools.
 */
import { findAssistantTool, validateToolArguments, type AssistantToolName } from './tools';
import type {
  AssistantCompletionPort,
  AssistantMessage,
  AssistantToolExecutorPort,
  AssistantToolResult,
} from './ports';

/** A mutating call the model asked for. Never executed here; the UI confirms it. */
export interface AssistantProposal {
  readonly id: string;
  readonly tool: AssistantToolName;
  readonly arguments: Readonly<Record<string, unknown>>;
}

export interface AgentLoopCommand {
  readonly systemPrompt: string;
  readonly messages: readonly AssistantMessage[];
  /** Pre-read state injected before the first completion so cheap questions cost zero rounds. */
  readonly seedContext: string;
  readonly preferredRuntime?: string;
  readonly model?: string;
  readonly maxRounds: number;
  readonly signal?: AbortSignal;
}

export interface AgentLoopOutcome {
  readonly content: string;
  readonly toolsUsed: readonly AssistantToolName[];
  readonly proposals: readonly AssistantProposal[];
  readonly results: readonly AssistantToolResult[];
  readonly rounds: number;
  readonly answeredBy: string;
}

export interface AgentLoopDependencies {
  readonly tools: AssistantToolExecutorPort;
  readonly completion: AssistantCompletionPort;
}

interface ParsedCall {
  readonly name: string;
  readonly arguments: Record<string, unknown>;
}

/**
 * Pulls tool calls out of fenced blocks. Accepts ```ralph, ```ralph-tool and
 * ```json because runtimes differ in how faithfully they reproduce an
 * uncommon info string; a ```json block only counts when it actually parses
 * to a tool-call shape, so ordinary JSON in an answer is left alone.
 */
export function parseToolCalls(text: string): readonly ParsedCall[] {
  const calls: ParsedCall[] = [];
  const fence = /```[ \t]*(ralph-tool|ralph|json)[ \t]*\r?\n([\s\S]*?)```/gi;
  for (const match of text.matchAll(fence)) {
    const tag = (match[1] ?? '').toLowerCase();
    const body = match[2] ?? '';
    let parsed: unknown;
    try {
      parsed = JSON.parse(body);
    } catch {
      continue;
    }
    for (const candidate of Array.isArray(parsed) ? parsed : [parsed]) {
      const call = asCall(candidate);
      if (!call) {
        continue;
      }
      // An untagged ```json block must name a real tool to count; otherwise
      // it is just JSON the model is showing the user.
      if (tag === 'json' && !findAssistantTool(call.name)) {
        continue;
      }
      calls.push(call);
    }
  }
  return calls;
}

function asCall(value: unknown): ParsedCall | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  const record = value as Record<string, unknown>;
  const name = record['tool'] ?? record['name'];
  if (typeof name !== 'string' || !name.trim()) {
    return null;
  }
  const rawArgs = record['arguments'] ?? record['args'] ?? {};
  const args = rawArgs && typeof rawArgs === 'object' && !Array.isArray(rawArgs) ? (rawArgs as Record<string, unknown>) : {};
  return { name: name.trim(), arguments: args };
}

/** Removes the tool blocks from prose shown to the user. */
export function stripToolBlocks(text: string): string {
  return text
    .replace(/```[ \t]*(ralph-tool|ralph)[ \t]*\r?\n[\s\S]*?```/gi, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2) ?? 'null';
  } catch {
    return '"<unserializable>"';
  }
}

function renderResults(results: readonly AssistantToolResult[]): string {
  return results.map((entry) => `## ${entry.name}\n${safeStringify(entry.result)}`).join('\n\n');
}

export async function runAgentLoop(
  dependencies: AgentLoopDependencies,
  command: AgentLoopCommand,
): Promise<AgentLoopOutcome> {
  const conversation: AssistantMessage[] = [
    { role: 'system', content: command.seedContext },
    ...command.messages,
  ];
  const used: AssistantToolName[] = [];
  const collected: AssistantToolResult[] = [];
  let answeredBy = '';
  let content = '';
  let rounds = 0;

  for (let round = 0; round < Math.max(1, command.maxRounds); round++) {
    rounds = round + 1;
    const lastRound = round === Math.max(1, command.maxRounds) - 1;
    const completion = await dependencies.completion.complete(
      {
        systemPrompt: lastRound ? `${command.systemPrompt}\n\nYou have no tool budget left. Answer now using what you already know; do not emit a ralph block requesting more data.` : command.systemPrompt,
        messages: conversation,
        ...(command.preferredRuntime ? { preferredRuntime: command.preferredRuntime } : {}),
        ...(command.model ? { model: command.model } : {}),
      },
      command.signal,
    );
    answeredBy = completion.answeredBy;
    content = completion.content;

    const calls = parseToolCalls(completion.content);
    if (calls.length === 0) {
      break;
    }

    // A proposal ends the turn: the user has to answer the confirm card
    // before anything else is worth doing.
    const proposals = collectProposals(calls);
    if (proposals.length > 0) {
      return {
        content: stripToolBlocks(content),
        toolsUsed: used,
        proposals,
        results: collected,
        rounds,
        answeredBy,
      };
    }

    if (lastRound) {
      break;
    }

    const results = await executeLoopCalls(dependencies.tools, calls);
    collected.push(...results);
    used.push(...results.map((entry) => entry.name));
    conversation.push({ role: 'assistant', content: completion.content });
    conversation.push({
      role: 'system',
      content: `TOOL RESULTS (round ${round + 1})\n\n${renderResults(results)}`,
    });
  }

  return {
    content: stripToolBlocks(content),
    toolsUsed: used,
    proposals: [],
    results: collected,
    rounds,
    answeredBy,
  };
}

function collectProposals(calls: readonly ParsedCall[]): readonly AssistantProposal[] {
  const proposals: AssistantProposal[] = [];
  for (const call of calls) {
    const tool = findAssistantTool(call.name);
    if (!tool || tool.kind !== 'propose') {
      continue;
    }
    // A malformed proposal is dropped rather than shown: a confirm card with
    // missing required fields is worse than no card.
    if (validateToolArguments(tool, call.arguments) !== null) {
      continue;
    }
    proposals.push({
      id: `${tool.name}-${proposals.length}`,
      tool: tool.name,
      arguments: call.arguments,
    });
  }
  return proposals;
}

async function executeLoopCalls(
  executor: AssistantToolExecutorPort,
  calls: readonly ParsedCall[],
): Promise<readonly AssistantToolResult[]> {
  const results: AssistantToolResult[] = [];
  const seen = new Set<string>();
  for (const call of calls) {
    const tool = findAssistantTool(call.name);
    if (!tool) {
      continue;
    }
    // Repeating an identical call inside one round buys nothing but prompt bytes.
    const key = `${call.name}:${safeStringify(call.arguments)}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);

    const invalid = validateToolArguments(tool, call.arguments);
    if (invalid) {
      results.push({ name: tool.name, result: { error: invalid } });
      continue;
    }
    try {
      results.push({ name: tool.name, result: await executor.execute({ name: tool.name, arguments: call.arguments }) });
    } catch (error: unknown) {
      results.push({ name: tool.name, result: { error: error instanceof Error ? error.message : 'tool failed' } });
    }
  }
  return results;
}
