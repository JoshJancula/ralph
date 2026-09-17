/**
 * Bridges the assistant to local agent CLIs without a shell. Ported intent
 * from trade-beacon's ralph-completion.adapter.ts, with its antigravity row
 * corrected against `bundle/.ralph/bash-lib/run-plan/run-plan-invoke-*.sh`
 * and each installed CLI's own `--help` (see port-design.md "Assistant
 * runtimes" for the verification record — the table below is NOT copied
 * from trade-beacon).
 *
 * Unlike `run-plan`'s full agentic invocation, this is a minimal,
 * non-interactive, read-only prompt/print call: cwd is a fresh empty temp
 * directory per request (no project hooks, MCP servers, or instruction
 * files load, and there is nothing to edit), stdin is closed unless the
 * runtime's transport is stdin, and the whole call is killed — by process
 * group — on a 120s timeout or client disconnect.
 */
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolveRuntimeBinary, installedRuntimes, type SupportedRuntime } from '../ralph-cli';
import type { AssistantCompletionPort, AssistantCompletionRequest, AssistantCompletionResult } from './ports';

type PromptTransport = 'stdin' | 'argument';

interface CompletionRuntimeDescriptor {
  readonly label: string;
  readonly baseArgs: readonly string[];
  readonly promptTransport: PromptTransport;
  /** Inserted as `--model <value>` right before the prompt argument (argument transport) or appended to baseArgs (stdin transport). */
  readonly modelFlag: string;
}

const COMPLETION_RUNTIMES: Record<SupportedRuntime, CompletionRuntimeDescriptor> = {
  claude: { label: 'Claude (Anthropic)', baseArgs: ['-p', '--output-format', 'text'], promptTransport: 'stdin', modelFlag: '--model' },
  codex: {
    label: 'Codex (OpenAI)',
    baseArgs: ['exec', '--skip-git-repo-check', '--sandbox', 'read-only', '--json'],
    promptTransport: 'stdin',
    modelFlag: '--model',
  },
  // Match trade-beacon: ask mode + JSON so parseCursorResult can read `{ result }`.
  // `--` keeps the prompt from being parsed as flags. Do not request text format here.
  cursor: {
    label: 'Cursor Agent',
    // Each dashboard turn uses an empty, disposable workspace so no project
    // hooks or instructions run. Cursor otherwise asks an interactive trust
    // question for that generated directory, which a web request cannot
    // answer. Ask mode remains read-only; --trust only suppresses that prompt.
    baseArgs: ['--print', '--mode', 'ask', '--trust', '--output-format', 'json', '--'],
    promptTransport: 'argument',
    modelFlag: '--model',
  },
  opencode: { label: 'OpenCode', baseArgs: ['run', '--agent', 'build'], promptTransport: 'argument', modelFlag: '--model' },
  antigravity: { label: 'Antigravity (Google)', baseArgs: ['-p', '--mode', 'plan', '--output-format', 'text'], promptTransport: 'argument', modelFlag: '--model' },
};

/** 120s in production; RALPH_DASHBOARD_ASSISTANT_TIMEOUT_MS overrides for fast timeout tests. Read per-call, not cached, so tests can change it after this module has already loaded. */
function completionTimeoutMs(): number {
  return Number(process.env['RALPH_DASHBOARD_ASSISTANT_TIMEOUT_MS'] ?? 120_000);
}

function withModel(baseArgs: readonly string[], modelFlag: string, model: string | undefined): string[] {
  if (!model) {
    return [...baseArgs];
  }
  const modelArgs = [modelFlag, model];
  const terminator = baseArgs.indexOf('--');
  if (terminator < 0) {
    return [...baseArgs, ...modelArgs];
  }
  // Insert --model before `--` so the prompt argument stays the final operand.
  return [...baseArgs.slice(0, terminator), ...modelArgs, ...baseArgs.slice(terminator)];
}

/** Flattens conversation roles into the one prompt accepted by local CLIs. Ported verbatim from trade-beacon (engine-agnostic). */
export function renderPrompt(request: AssistantCompletionRequest): string {
  const lines = [request.systemPrompt, ''];
  for (const message of request.messages) {
    lines.push(message.role === 'user' ? `User: ${message.content}` : message.content);
    lines.push('');
  }
  lines.push('Answer the final user message.');
  return lines.join('\n');
}

export function parseCursorResult(stdout: string): string {
  const trimmed = stdout.trim();
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (parsed && typeof parsed === 'object' && 'result' in parsed && typeof (parsed as { result: unknown }).result === 'string') {
      return (parsed as { result: string }).result.trim();
    }
  } catch {
    // fall through
  }
  // Some cursor-agent builds emit one JSON object per line (stream-adjacent).
  const lines = trimmed.split('\n').map((line) => line.trim()).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    try {
      const parsed: unknown = JSON.parse(lines[i]!);
      if (parsed && typeof parsed === 'object' && 'result' in parsed && typeof (parsed as { result: unknown }).result === 'string') {
        return (parsed as { result: string }).result.trim();
      }
    } catch {
      // keep scanning
    }
  }
  throw new Error('cursor-agent returned malformed JSON output');
}

export class RalphAssistantCompletion implements AssistantCompletionPort {
  async isAvailable(): Promise<boolean> {
    const installed = await installedRuntimes();
    return (Object.keys(COMPLETION_RUNTIMES) as SupportedRuntime[]).some((runtime) => installed[runtime]);
  }

  async listRuntimes(): Promise<readonly { id: string; label: string; installed: boolean }[]> {
    const installed = await installedRuntimes();
    return (Object.keys(COMPLETION_RUNTIMES) as SupportedRuntime[]).map((id) => ({
      id,
      label: COMPLETION_RUNTIMES[id].label,
      installed: installed[id],
    }));
  }

  async complete(request: AssistantCompletionRequest, signal?: AbortSignal): Promise<AssistantCompletionResult> {
    const runtimeId = await this.resolveRuntime(request.preferredRuntime);
    if (!runtimeId) {
      throw new Error('Choose an installed agent runtime');
    }
    const descriptor = COMPLETION_RUNTIMES[runtimeId];
    const binary = resolveRuntimeBinary(runtimeId);
    if (!binary) {
      throw new Error(`No binary found on PATH for runtime '${runtimeId}'`);
    }

    const prompt = renderPrompt(request);
    const args = withModel(descriptor.baseArgs, descriptor.modelFlag, request.model);
    if (descriptor.promptTransport === 'argument') {
      args.push(prompt);
    }

    const cwd = await mkdtemp(join(tmpdir(), 'ralph-assistant-'));
    try {
      const result = await this.runIsolated(binary, args, cwd, descriptor.promptTransport === 'stdin' ? prompt : undefined, signal);
      if (result.timedOut) {
        throw new Error(`${binary} did not answer within ${completionTimeoutMs() / 1000}s`);
      }
      if (result.code !== 0) {
        throw new Error(`${binary} failed: ${result.stderr.slice(0, 200) || `exit ${result.code}`}`);
      }
      const content = runtimeId === 'cursor' ? parseCursorResult(result.stdout) : result.stdout.trim();
      if (!content) {
        throw new Error(`${binary} returned no assistant response`);
      }
      return { content, answeredBy: `${descriptor.label} (local agent CLI)` };
    } finally {
      await rm(cwd, { recursive: true, force: true }).catch(() => undefined);
    }
  }

  private runIsolated(
    binary: string,
    args: readonly string[],
    cwd: string,
    stdin: string | undefined,
    signal: AbortSignal | undefined,
  ): Promise<{ stdout: string; stderr: string; code: number | null; timedOut: boolean }> {
    return new Promise((resolvePromise) => {
      const child = spawn(binary, args, {
        cwd,
        stdio: [stdin !== undefined ? 'pipe' : 'ignore', 'pipe', 'pipe'],
        detached: true,
        windowsHide: true,
      });
      let stdout = '';
      let stderr = '';
      let timedOut = false;
      let settled = false;

      const killGroup = () => {
        if (typeof child.pid === 'number') {
          try {
            process.kill(-child.pid, 'SIGKILL');
          } catch {
            child.kill('SIGKILL');
          }
        }
      };

      const timer = setTimeout(() => {
        timedOut = true;
        killGroup();
      }, completionTimeoutMs());

      const onAbort = () => killGroup();
      signal?.addEventListener('abort', onAbort);

      child.stdout?.on('data', (chunk: Buffer) => {
        stdout += chunk.toString('utf8');
      });
      child.stderr?.on('data', (chunk: Buffer) => {
        stderr += chunk.toString('utf8');
      });
      child.on('close', (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', onAbort);
        resolvePromise({ stdout, stderr, code, timedOut });
      });
      child.on('error', (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', onAbort);
        stderr += error.message;
        resolvePromise({ stdout, stderr, code: null, timedOut });
      });

      if (stdin !== undefined) {
        child.stdin?.end(stdin);
      }
    });
  }

  private async resolveRuntime(preferred?: string): Promise<SupportedRuntime | null> {
    if (!preferred || !(preferred in COMPLETION_RUNTIMES)) {
      return null;
    }
    const runtime = preferred as SupportedRuntime;
    return resolveRuntimeBinary(runtime) ? runtime : null;
  }
}
