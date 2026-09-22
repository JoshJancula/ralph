/**
 * Plain TypeScript interfaces (no DI symbols — the dashboard is plain
 * Express, not NestJS). Ported from trade-beacon's
 * libs/domain-assistant/src/ports/assistant.ports.ts. See port-design.md
 * "Component decisions".
 */
import type { AssistantToolName } from './tools';

export interface AssistantToolCall {
  readonly name: AssistantToolName;
  /** Widened from string-only: object/array parameters carry workflow models, task lists, and worker configs. */
  readonly arguments: Readonly<Record<string, unknown>>;
}

export interface AssistantToolResult {
  readonly name: AssistantToolName;
  readonly result: unknown;
}

export interface AssistantToolExecutorPort {
  execute(call: AssistantToolCall): Promise<unknown>;
}

export type AssistantRole = 'user' | 'assistant' | 'system';

export interface AssistantMessage {
  readonly role: AssistantRole;
  readonly content: string;
}

export interface AssistantCompletionRequest {
  readonly systemPrompt: string;
  readonly messages: readonly AssistantMessage[];
  /** Preferred agent runtime id. Auto-discovers when omitted. */
  readonly preferredRuntime?: string;
  /** Model to forward to the agent CLI. Falls back to the CLI default when omitted. */
  readonly model?: string;
}

/** Completion text plus per-request provenance, safe under concurrent chats. */
export interface AssistantCompletionResult {
  readonly content: string;
  readonly answeredBy: string;
}

export interface AssistantCompletionPort {
  /** Whether an agent runtime is actually available right now. */
  isAvailable(): Promise<boolean>;
  complete(request: AssistantCompletionRequest, signal?: AbortSignal): Promise<AssistantCompletionResult>;
}
