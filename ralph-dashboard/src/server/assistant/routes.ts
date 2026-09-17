import type { Express, Request, Response } from 'express';
import { resolveWorkflowWorkspaceContext } from '../dashboard-api';
import { listModels } from '../ralph-cli';
import { writeGuard } from '../write-guard';
import { AssistantService, AssistantValidationError, type AssistantApprovedAction } from './assistant-service';
import { RalphAssistantCompletion } from './completion';
import { createAssistantToolExecutor } from './tool-executor';
import { ASSISTANT_TOOLS, isMutatingTool } from './tools';

const completion = new RalphAssistantCompletion();

function jsonError(res: Response, status: number, message: string): void {
  res.status(status).json({ error: message });
}

function handleTools(_req: Request, res: Response): void {
  // `mutating` is kept alongside `kind` so older clients keep working.
  res.json(
    ASSISTANT_TOOLS.map((tool) => ({
      name: tool.name,
      description: tool.description,
      kind: tool.kind,
      mutating: isMutatingTool(tool),
      parameters: tool.parameters,
    })),
  );
}

async function handleRuntimes(_req: Request, res: Response): Promise<void> {
  res.json(await completion.listRuntimes());
}

async function handleRuntimeModels(req: Request, res: Response): Promise<void> {
  const runtime = String(req.params['runtime'] ?? '').trim();
  const available = await completion.listRuntimes();
  if (!available.some((candidate) => candidate.id === runtime && candidate.installed)) {
    jsonError(res, 400, 'Choose an installed assistant runtime');
    return;
  }
  const context = await resolveWorkflowWorkspaceContext(req);
  if (context === null) {
    jsonError(res, 400, 'invalid workspaceRoot');
    return;
  }
  try {
    res.json(
      (
        await listModels(runtime, {
          cwd: context.projectRoot,
          projectRoot: context.projectRoot,
          workspaceRoot: context.workspaceRoot,
        })
      ).map((id) => ({ id, label: id })),
    );
  } catch (error: unknown) {
    jsonError(res, 502, error instanceof Error ? error.message : 'Could not list runtime models');
  }
}

async function handleChat(req: Request, res: Response): Promise<void> {
  const body = (req.body ?? {}) as Record<string, unknown>;
  const rawMessages = Array.isArray(body['messages']) ? body['messages'] : null;
  if (!rawMessages) {
    jsonError(res, 400, 'messages array is required');
    return;
  }
  const messages = rawMessages
    .filter((m): m is Record<string, unknown> => !!m && typeof m === 'object')
    .map((m) => ({ role: m['role'], content: m['content'] }))
    .filter((m): m is { role: 'user' | 'assistant' | 'system'; content: string } => ['user', 'assistant', 'system'].includes(m.role as string) && typeof m.content === 'string');
  if (messages.length === 0) {
    jsonError(res, 400, 'messages array must contain at least one valid message');
    return;
  }

  let approvedAction: AssistantApprovedAction | undefined;
  const rawApproved = body['approvedAction'];
  if (rawApproved && typeof rawApproved === 'object') {
    const record = rawApproved as Record<string, unknown>;
    if (typeof record['tool'] === 'string') {
      const args = record['arguments'] && typeof record['arguments'] === 'object' ? (record['arguments'] as Record<string, unknown>) : {};
      approvedAction = { tool: record['tool'] as AssistantApprovedAction['tool'], arguments: args };
    }
  }

  const context = await resolveWorkflowWorkspaceContext(req);
  if (context === null) {
    jsonError(res, 400, 'invalid workspaceRoot');
    return;
  }
  const service = new AssistantService({ tools: createAssistantToolExecutor(context), completion });

  const controller = new AbortController();
  res.on('close', () => controller.abort());

  try {
    const reply = await service.chat({
      messages,
      pageContext: typeof body['pageContext'] === 'string' ? body['pageContext'] : undefined,
      approvedAction,
      preferredRuntime: typeof body['runtime'] === 'string' ? body['runtime'] : undefined,
      model: typeof body['model'] === 'string' ? body['model'] : undefined,
      signal: controller.signal,
    });
    res.json(reply);
  } catch (error: unknown) {
    if (error instanceof AssistantValidationError) {
      jsonError(res, 400, error.message);
      return;
    }
    jsonError(res, 502, error instanceof Error ? error.message : 'assistant chat failed');
  }
}

export function registerAssistantApi(app: Express): void {
  app.get('/api/assistant/tools', handleTools);
  app.get('/api/assistant/runtimes', handleRuntimes);
  app.get('/api/assistant/runtimes/:runtime/models', handleRuntimeModels);
  app.post('/api/assistant/chat', writeGuard, handleChat);
}
