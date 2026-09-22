import { HttpClient } from '@angular/common/http';
import { Injectable, PLATFORM_ID, inject, signal } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { Router } from '@angular/router';
import { firstValueFrom } from 'rxjs';
import { ErrorDialogService } from '../services/error-dialog.service';
import { TasksSchedulesService } from '../services/tasks-schedules.service';
import { WorkflowsApi } from '../workflows/workflows-api.service';
import type {
  AssistantApprovedAction,
  AssistantChatMessage,
  AssistantChatResponse,
  AssistantModelSummary,
  AssistantProposalView,
  AssistantRuntimeSummary,
  AssistantToolSummary,
} from './assistant.types';

const STORAGE_KEY = 'ralph-assistant-v1';

interface PersistedState {
  readonly version: 1;
  readonly messages: readonly AssistantChatMessage[];
  readonly selectedRuntime: string | null;
  readonly selectedModel: string;
}

/**
 * Ported from trade-beacon's core/assistant/assistant.store.ts. Root-
 * provided so the conversation survives navigation — the dock follows the
 * user around the dashboard rather than resetting per page. See
 * port-design.md "Component decisions": storage key changes to
 * `ralph-assistant-v1`, and mutating suggestions require an explicit
 * `AssistantApprovedAction` object, never a regex over the draft text.
 */
@Injectable({ providedIn: 'root' })
export class AssistantStore {
  private readonly http = inject(HttpClient);
  private readonly router = inject(Router);
  private readonly platformId = inject(PLATFORM_ID);
  private readonly tasksSchedules = inject(TasksSchedulesService);
  private readonly workflowsApi = inject(WorkflowsApi);
  private readonly errorDialog = inject(ErrorDialogService);

  readonly open = signal(false);
  readonly prefilledDraft = signal('');
  readonly messages = signal<readonly AssistantChatMessage[]>([]);
  readonly sending = signal(false);
  readonly error = signal<string | null>(null);
  readonly tools = signal<readonly AssistantToolSummary[]>([]);
  readonly runtimes = signal<readonly AssistantRuntimeSummary[]>([]);
  readonly models = signal<readonly AssistantModelSummary[]>([]);
  readonly lastAnsweredBy = signal<string | null>(null);
  readonly lastDegraded = signal(false);
  /** Changes the assistant is asking the user to confirm. Cleared on each new turn. */
  readonly proposals = signal<readonly AssistantProposalView[]>([]);
  readonly committing = signal<string | null>(null);

  /** A runtime must be explicitly selected before a message can be sent. */
  readonly selectedRuntime = signal<string | null>(null);
  /** Empty string means CLI default. */
  readonly selectedModel = signal<string>('');

  constructor() {
    this.restoreFromStorage();
  }

  toggle(): void {
    this.open.update((value) => !value);
    if (this.open()) {
      if (this.tools().length === 0) void this.loadTools();
      if (this.runtimes().length === 0) void this.loadRuntimes();
    }
  }

  close(): void {
    this.open.set(false);
  }

  openWithPrefilledDraft(draft: string): void {
    this.prefilledDraft.set(draft);
    this.open.set(true);
    if (this.tools().length === 0) void this.loadTools();
    if (this.runtimes().length === 0) void this.loadRuntimes();
  }

  consumePrefilledDraft(): string {
    const draft = this.prefilledDraft();
    this.prefilledDraft.set('');
    return draft;
  }

  clear(): void {
    this.messages.set([]);
    this.proposals.set([]);
    this.error.set(null);
    this.lastAnsweredBy.set(null);
    this.lastDegraded.set(false);
    this.persist();
  }

  setRuntime(id: string | null): void {
    if (id === this.selectedRuntime()) return;
    this.selectedRuntime.set(id);
    this.selectedModel.set('');
    this.models.set([]);
    if (id) void this.loadModels(id);
    this.startNewChat(id, '');
  }

  setModel(model: string): void {
    const trimmed = model.trim();
    if (trimmed === this.selectedModel()) return;
    this.selectedModel.set(trimmed);
    this.startNewChat(this.selectedRuntime(), trimmed);
  }

  async loadTools(): Promise<void> {
    try {
      this.tools.set(await firstValueFrom(this.http.get<readonly AssistantToolSummary[]>('/api/assistant/tools')));
    } catch {
      // Non-fatal: the dock still works without the tool list (used only for the "what it can reach" disclosure).
    }
  }

  async loadRuntimes(): Promise<void> {
    try {
      const runtimes = await firstValueFrom(this.http.get<readonly AssistantRuntimeSummary[]>('/api/assistant/runtimes'));
      this.runtimes.set(runtimes);
      const selected = this.selectedRuntime();
      if (!selected) return;
      if (!runtimes.some((runtime) => runtime.id === selected && runtime.installed)) {
        this.setRuntime(null);
        return;
      }
      // Restored selections skip setRuntime(), so models must be loaded here.
      if (this.models().length === 0) void this.loadModels(selected);
    } catch {
      // Non-fatal.
    }
  }

  async loadModels(runtime: string): Promise<void> {
    try {
      const models = await firstValueFrom(this.http.get<readonly AssistantModelSummary[]>(`/api/assistant/runtimes/${encodeURIComponent(runtime)}/models`));
      if (this.selectedRuntime() === runtime) this.models.set(models);
    } catch {
      // A custom model can still be entered when native discovery is unavailable.
      if (this.selectedRuntime() === runtime) this.models.set([]);
    }
  }

  /** Sends a plain user message. No tool runs unless the assistant's own read tools ran server-side, which never mutate. */
  async send(draft: string): Promise<boolean> {
    return this.dispatch(draft, undefined);
  }

  /**
   * Sends an explicit, user-approved mutating tool call. `description`
   * becomes the visible user-turn message (e.g. "Start workflow bug-fix").
   * This is the only path that can execute a mutating tool — never inferred
   * from what the assistant said.
   */
  async sendApprovedAction(description: string, action: AssistantApprovedAction): Promise<boolean> {
    return this.dispatch(description, action);
  }

  /**
   * Commits one confirmed proposal.
   *
   * Task, schedule, and workflow proposals are posted to the same guarded
   * REST routes the rest of the dashboard uses, so their validation is never
   * duplicated into an assistant-only write path. `start_workflow` and
   * `cancel_run` keep the older server-side approved-action path, which
   * already executes them and feeds the result back into the conversation.
   */
  async commitProposal(proposal: AssistantProposalView): Promise<boolean> {
    if (this.committing()) {
      return false;
    }
    const args = proposal.arguments as Record<string, never>;
    this.committing.set(proposal.id);
    this.error.set(null);
    try {
      switch (proposal.tool) {
        case 'start_workflow':
        case 'cancel_run':
          this.committing.set(null);
          this.dismissProposal(proposal.id);
          return this.sendApprovedAction(proposal.title, { tool: proposal.tool, arguments: proposal.arguments });
        case 'create_task':
          await firstValueFrom(this.tasksSchedules.createTask(args));
          break;
        case 'create_tasks': {
          const tasks = Array.isArray(proposal.arguments['tasks']) ? (proposal.arguments['tasks'] as never[]) : [];
          for (const task of tasks) {
            await firstValueFrom(this.tasksSchedules.createTask(task));
          }
          break;
        }
        case 'update_task':
          await firstValueFrom(this.tasksSchedules.patchTask(String(proposal.arguments['id']), args));
          break;
        case 'launch_task':
          await firstValueFrom(this.tasksSchedules.launchTask(String(proposal.arguments['id'])));
          break;
        case 'create_schedule':
          await firstValueFrom(this.tasksSchedules.createSchedule(args));
          break;
        case 'update_schedule':
          await firstValueFrom(this.tasksSchedules.patchSchedule(String(proposal.arguments['id']), args));
          break;
        case 'create_workflow': {
          const model = (proposal.arguments['model'] ?? {}) as Record<string, unknown>;
          await firstValueFrom(
            this.workflowsApi.createWorkflow({ id: String(proposal.arguments['id']), scope: proposal.arguments['scope'], ...model } as never),
          );
          break;
        }
        default:
          {
            const message = `${proposal.tool} cannot be applied from here`;
            this.error.set(message);
            void this.errorDialog.displayError(message);
          }
          return false;
      }
      this.dismissProposal(proposal.id);
      this.messages.update((messages) => [...messages, { role: 'assistant' as const, content: `Done: ${proposal.title}.` }]);
      this.persist();
      return true;
    } catch (error: unknown) {
      const message = formatError(error);
      this.error.set(message);
      void this.errorDialog.displayError(error, message);
      return false;
    } finally {
      this.committing.set(null);
    }
  }

  dismissProposal(id: string): void {
    this.proposals.update((proposals) => proposals.filter((proposal) => proposal.id !== id));
  }

  private async dispatch(draft: string, approvedAction: AssistantApprovedAction | undefined): Promise<boolean> {
    const content = draft.trim();
    if (!content || this.sending() || !this.selectedRuntime()) {
      if (content && !this.selectedRuntime()) {
        const message = 'Choose a runtime before sending a message';
        this.error.set(message);
        void this.errorDialog.displayError(message);
      }
      return false;
    }
    const prior = this.messages();
    const optimistic: readonly AssistantChatMessage[] = [...prior, { role: 'user', content }];
    this.messages.set(optimistic);
    this.sending.set(true);
    this.error.set(null);
    this.proposals.set([]);
    try {
      const body: Record<string, unknown> = { messages: optimistic, pageContext: this.pageContext() };
      const runtime = this.selectedRuntime();
      if (runtime) body['runtime'] = runtime;
      const model = this.selectedModel();
      if (model) body['model'] = model;
      if (approvedAction) body['approvedAction'] = approvedAction;

      const reply = await firstValueFrom(this.http.post<AssistantChatResponse>('/api/assistant/chat', body));
      const updated = [...optimistic, { role: 'assistant' as const, content: reply.content }];
      this.messages.set(updated);
      this.lastAnsweredBy.set(reply.answeredBy);
      this.lastDegraded.set(reply.degraded);
      this.proposals.set(reply.proposals ?? []);
      this.persist();
      return true;
    } catch (error: unknown) {
      // Roll the optimistic message back so a retry does not duplicate it.
      this.messages.set(prior);
      const message = formatError(error);
      this.error.set(message);
      void this.errorDialog.displayError(error, message);
      return false;
    } finally {
      this.sending.set(false);
    }
  }

  private pageContext(): string {
    const url = this.router.url;
    return url;
  }

  private startNewChat(runtime: string | null, model: string): void {
    this.error.set(null);
    this.proposals.set([]);
    this.lastAnsweredBy.set(null);
    this.lastDegraded.set(false);
    if (!runtime) {
      this.messages.set([]);
      this.persist();
      return;
    }
    const label = this.runtimes().find((candidate) => candidate.id === runtime)?.label ?? runtime;
    const modelLabel = model || 'runtime default model';
    this.messages.set([
      {
        role: 'assistant',
        content: `New chat started with ${label} · ${modelLabel}. Previous messages are not included.`,
      },
    ]);
    this.persist();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  private persist(): void {
    if (!isPlatformBrowser(this.platformId)) return;
    try {
      const state: PersistedState = {
        version: 1,
        messages: this.messages(),
        selectedRuntime: this.selectedRuntime(),
        selectedModel: this.selectedModel(),
      };
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch {
      // Storage quota or serialization errors must not crash the UI.
    }
  }

  private restoreFromStorage(): void {
    if (!isPlatformBrowser(this.platformId)) return;
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const state = JSON.parse(raw) as PersistedState;
      if (state.version !== 1) return;
      if (Array.isArray(state.messages)) {
        this.messages.set(state.messages);
      }
      if (typeof state.selectedRuntime === 'string' || state.selectedRuntime === null) {
        this.selectedRuntime.set(state.selectedRuntime);
      }
      if (typeof state.selectedModel === 'string') {
        this.selectedModel.set(state.selectedModel);
      }
    } catch {
      // Corrupted storage — start fresh.
    }
  }
}

function formatError(error: unknown): string {
  if (error && typeof error === 'object' && 'error' in error) {
    const body = (error as { error?: unknown }).error;
    if (body && typeof body === 'object' && 'error' in body && typeof (body as { error: unknown }).error === 'string') {
      return (body as { error: string }).error;
    }
  }
  return 'Assistant failed';
}
