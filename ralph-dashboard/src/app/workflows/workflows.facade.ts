import { Injectable, computed, effect, inject, signal } from '@angular/core';
import { HttpErrorResponse } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { ErrorDialogService } from '../services/error-dialog.service';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { isAllWorkspacesMode } from './workflow-scope.helpers';
import { WorkflowsApi } from './workflows-api.service';
import type {
  ApiErrorBody,
  CreateWorkflowCommand,
  CustomizeWorkflowCommand,
  CustomizeWorkflowResponse,
  ModelDescriptor,
  RespondActionCommand,
  RunListItem,
  RunStatus,
  RuntimeDescriptor,
  StartWorkflowCommand,
  StartWorkflowResponse,
  UpdateWorkflowCommand,
  WorkflowDetail,
  WorkflowListItem,
  WorkflowRoutingPatch,
  WorkflowScope,
  WritableWorkflowScope,
} from './workflow.types';
import { matchesWorkflowCatalogSearch } from './workflow-catalog.helpers';

/**
 * Ported from trade-beacon's workflows.facade.ts. Drops archive, revive,
 * resetToTemplate, schedule preview, portfolios, and watchlists — Ralph has
 * no equivalent (see port-design.md "Component decisions"). Adds sha256
 * dirty-state tracking for save-conflict handling, which trade-beacon did
 * not need (its workflows are TypeORM rows, not files with concurrent
 * editors).
 */

/** Run states that stop polling. `waiting` (human action pending) and anything else keep polling. */
const TERMINAL_RUN_STATES: ReadonlySet<string> = new Set(['succeeded', 'failed', 'cancelled']);

function isLiveState(state: string): boolean {
  return !TERMINAL_RUN_STATES.has(state);
}

@Injectable({ providedIn: 'root' })
export class WorkflowsFacade {
  private readonly api = inject(WorkflowsApi);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);
  private readonly errorDialog = inject(ErrorDialogService);

  readonly loading = signal(true);
  readonly loaded = signal(false);
  readonly saving = signal(false);
  readonly error = signal<string | null>(null);

  readonly workflows = signal<readonly WorkflowListItem[]>([]);
  readonly catalogSearch = signal('');
  readonly filteredWorkflows = computed(() => {
    const query = this.catalogSearch();
    return this.workflows().filter((item) => matchesWorkflowCatalogSearch(item, query));
  });
  readonly runtimes = signal<readonly RuntimeDescriptor[]>([]);
  readonly modelsByRuntime = signal<ReadonlyMap<string, readonly ModelDescriptor[]>>(new Map());

  readonly selectedId = signal<string | null>(null);
  readonly selected = signal<WorkflowDetail | null>(null);
  readonly selectedScope = signal<WorkflowScope | null>(null);
  readonly editDirty = signal(false);
  readonly builderDirty = signal(false);

  readonly runs = signal<readonly RunListItem[]>([]);
  readonly runsLoading = signal(false);
  readonly runStatus = signal<RunStatus | null>(null);

  readonly triggeringIds = signal<ReadonlySet<string>>(new Set());

  /** True when multiple projects are registered but the sidebar has no single-project selection. */
  readonly needsProjectSelection = computed(() =>
    isAllWorkspacesMode(this.workspaceSelector.workspaces(), this.workspaceSelector.selectedWorkspacePath()),
  );

  private static readonly RUNS_POLL_MS = 4000;
  private static readonly RUN_STATUS_POLL_MS = 3000;
  private runsPollTimer: ReturnType<typeof setInterval> | null = null;
  private runStatusPollTimer: ReturnType<typeof setInterval> | null = null;
  /** Run ids dropped after a 404 so list refresh does not resurrect ghosts. */
  private readonly evictedRunIds = new Set<string>();
  private requestGeneration = 0;
  private lastWorkspaceContextKey: string | undefined;
  /** Workspace root used for the currently loaded `selected` detail; drives reload on switch. */
  private detailWorkspaceRoot: string | undefined | null = null;

  constructor() {
    effect(() => {
      if (!this.workspaceSelector.hasLoadedOnce()) {
        return;
      }
      const contextKey = this.workspaceContextKey();
      if (this.lastWorkspaceContextKey === undefined) {
        this.lastWorkspaceContextKey = contextKey;
        void this.load();
        return;
      }
      if (contextKey === this.lastWorkspaceContextKey) {
        return;
      }
      this.lastWorkspaceContextKey = contextKey;
      void this.handleWorkspaceContextChange();
    });

    effect(() => {
      const id = this.selectedId();
      const root = this.workspaceRoot();
      if (!this.workspaceSelector.hasLoadedOnce() || !id || this.editDirty()) {
        return;
      }
      if (this.detailWorkspaceRoot === null) {
        return;
      }
      if (this.detailWorkspaceRoot === root) {
        return;
      }
      void this.openDetail(id, this.selectedScope() ?? undefined);
    });
  }

  private workspaceContextKey(): string {
    const selected = this.workspaceSelector.selectedWorkspacePath();
    const root = this.workspaceRoot();
    return `${selected ?? ''}\0${root ?? ''}`;
  }

  private bumpRequestGeneration(): void {
    this.requestGeneration += 1;
  }

  private isStaleRequest(generation: number): boolean {
    return generation !== this.requestGeneration;
  }

  private clearWorkspaceScopedState(preserveSelectionIdentity = false): void {
    this.stopRunsPolling();
    this.stopRunStatusPolling();
    this.editDirty.set(false);
    this.builderDirty.set(false);
    this.triggeringIds.set(new Set());
    this.modelsByRuntime.set(new Map());
    this.selected.set(null);
    this.detailWorkspaceRoot = null;
    if (!preserveSelectionIdentity) {
      this.selectedId.set(null);
      this.selectedScope.set(null);
    }
    this.evictedRunIds.clear();
    this.runs.set([]);
    this.runStatus.set(null);
  }

  private async handleWorkspaceContextChange(): Promise<void> {
    const hadSelection = Boolean(this.selectedId());
    this.bumpRequestGeneration();
    this.clearWorkspaceScopedState(hadSelection);
    if (hadSelection) {
      this.detailWorkspaceRoot = undefined;
    }
    this.error.set(null);
    const generation = this.requestGeneration;
    try {
      await Promise.all([this.refreshWorkflows(generation), this.loadRuntimes(generation)]);
      if (this.isStaleRequest(generation)) {
        return;
      }
    } catch (err: unknown) {
      if (!this.isStaleRequest(generation)) {
        this.handleError(err, 'Failed to load workflows for the selected workspace');
      }
    }
  }

  projectSelectionRequiredMessage(): string {
    return 'Select a project in the workspace switcher before project-scoped workflow actions.';
  }

  requireProjectSelection(): void {
    const message = this.projectSelectionRequiredMessage();
    this.error.set(message);
    void this.errorDialog.displayError(message);
  }

  private assertProjectWorkspaceForMutation(): boolean {
    if (!this.needsProjectSelection()) {
      return true;
    }
    const message = this.projectSelectionRequiredMessage();
    this.error.set(message);
    void this.errorDialog.displayError(message);
    return false;
  }

  private workspaceRoot(): string | undefined {
    const selected = this.workspaceSelector.selectedWorkspacePath();
    if (!selected) {
      return undefined;
    }
    return this.workspaceSelector.workspaces().find((w) => w.path === selected)?.workspaceRoot;
  }

  async load(): Promise<void> {
    if (!this.workspaceSelector.hasLoadedOnce()) {
      return;
    }
    if (!this.loaded()) {
      this.loading.set(true);
    }
    this.error.set(null);
    const generation = this.requestGeneration;
    try {
      await Promise.all([this.refreshWorkflows(generation), this.loadRuntimes(generation)]);
      if (!this.isStaleRequest(generation)) {
        this.loaded.set(true);
      }
    } catch (err: unknown) {
      if (!this.isStaleRequest(generation)) {
        this.handleError(err, 'Failed to load workflows');
        this.loaded.set(true);
      }
    } finally {
      if (!this.isStaleRequest(generation)) {
        this.loading.set(false);
      }
    }
  }

  async refresh(): Promise<void> {
    try {
      await this.refreshWorkflows();
      const id = this.selectedId();
      if (id && !this.editDirty()) {
        await this.openDetail(id, this.selectedScope() ?? undefined);
      }
    } catch (err: unknown) {
      this.handleError(err, 'Failed to refresh workflows');
    }
  }

  private async refreshWorkflows(generation = this.requestGeneration): Promise<void> {
    const list = await firstValueFrom(this.api.listWorkflows(this.workspaceRoot()));
    if (!this.isStaleRequest(generation)) {
      this.workflows.set(list);
    }
  }

  setCatalogSearch(query: string): void {
    this.catalogSearch.set(query);
  }

  private async loadRuntimes(generation = this.requestGeneration): Promise<void> {
    const runtimes = await firstValueFrom(this.api.listRuntimes());
    if (!this.isStaleRequest(generation)) {
      this.runtimes.set(runtimes);
    }
  }

  async openDetail(id: string, scope?: WorkflowScope, generation = this.requestGeneration): Promise<void> {
    this.error.set(null);
    this.selectedId.set(id);
    if (scope) {
      this.selectedScope.set(scope);
    }
    try {
      const detail = await firstValueFrom(this.api.getWorkflow(id, this.workspaceRoot(), scope));
      if (this.isStaleRequest(generation)) {
        return;
      }
      this.selected.set(detail);
      this.selectedId.set(id);
      this.selectedScope.set(detail.scope);
      this.editDirty.set(false);
      this.detailWorkspaceRoot = this.workspaceRoot();
      await this.loadRuns(id, generation);
    } catch (err: unknown) {
      if (!this.isStaleRequest(generation)) {
        this.handleError(err, 'Workflow not found');
      }
    }
  }

  async loadRuns(workflowId: string, generation = this.requestGeneration): Promise<void> {
    if (!this.isStaleRequest(generation)) {
      this.runsLoading.set(true);
    }
    try {
      const runs = await firstValueFrom(this.api.listWorkflowRuns(workflowId, this.workspaceRoot()));
      if (this.isStaleRequest(generation)) {
        return;
      }
      this.runs.set(runs.filter((run) => !this.evictedRunIds.has(run.runId)));
      this.ensureRunsPolling(workflowId);
    } catch {
      if (!this.isStaleRequest(generation)) {
        this.runs.set([]);
      }
    } finally {
      if (!this.isStaleRequest(generation)) {
        this.runsLoading.set(false);
      }
    }
  }

  stopRunsPolling(): void {
    if (this.runsPollTimer) {
      clearInterval(this.runsPollTimer);
      this.runsPollTimer = null;
    }
  }

  private ensureRunsPolling(workflowId: string, force = false): void {
    const live = force || this.runs().some((run) => isLiveState(run.state));
    if (!live) {
      this.stopRunsPolling();
      return;
    }
    if (this.runsPollTimer) {
      return;
    }
    this.runsPollTimer = setInterval(() => {
      if (this.selectedId() !== workflowId) {
        this.stopRunsPolling();
        return;
      }
      void this.loadRuns(workflowId);
    }, WorkflowsFacade.RUNS_POLL_MS);
  }

  async loadRunStatus(runId: string): Promise<void> {
    const generation = this.requestGeneration;
    try {
      const status = await firstValueFrom(this.api.getRunStatus(runId, this.workspaceRoot()));
      if (this.isStaleRequest(generation)) {
        return;
      }
      this.runStatus.set(status);
      this.ensureRunStatusPolling(runId);
    } catch (err: unknown) {
      if (!this.isStaleRequest(generation)) {
        if (err instanceof HttpErrorResponse && err.status === 404) {
          this.evictStaleRun(runId);
          return;
        }
        this.handleError(err, 'Failed to load run status');
      }
    }
  }

  stopRunStatusPolling(): void {
    if (this.runStatusPollTimer) {
      clearInterval(this.runStatusPollTimer);
      this.runStatusPollTimer = null;
    }
  }

  private ensureRunStatusPolling(runId: string): void {
    const state = String((this.runStatus()?.run as { state?: unknown } | undefined)?.state ?? '');
    if (!isLiveState(state)) {
      this.stopRunStatusPolling();
      return;
    }
    if (this.runStatusPollTimer) {
      return;
    }
    this.runStatusPollTimer = setInterval(() => {
      void this.loadRunStatus(runId);
    }, WorkflowsFacade.RUN_STATUS_POLL_MS);
  }

  markBuilderDirty(dirty: boolean): void {
    this.builderDirty.set(dirty);
  }

  markEditDirty(dirty: boolean): void {
    this.editDirty.set(dirty);
  }

  async create(command: CreateWorkflowCommand): Promise<boolean> {
    if (command.scope === 'project' && !this.assertProjectWorkspaceForMutation()) {
      return false;
    }
    this.saving.set(true);
    this.error.set(null);
    try {
      await firstValueFrom(this.api.createWorkflow(command, this.workspaceRoot()));
      this.builderDirty.set(false);
      await this.refreshWorkflows();
      return true;
    } catch (err: unknown) {
      this.handleError(err, 'Failed to create workflow');
      return false;
    } finally {
      this.saving.set(false);
    }
  }

  /** Returns 'ok', 'conflict' (stale sha256 — caller should offer reload-or-overwrite), or 'invalid' (422; diagnostics in `error`). */
  writableScope(detail: WorkflowDetail | null): WritableWorkflowScope | undefined {
    if (!detail) {
      return undefined;
    }
    if (detail.scope === 'project' || detail.scope === 'global') {
      return detail.scope;
    }
    return undefined;
  }

  async update(id: string, command: UpdateWorkflowCommand, scope?: WritableWorkflowScope): Promise<'ok' | 'conflict' | 'invalid'> {
    const activeScope = scope ?? this.writableScope(this.selected());
    if (activeScope === 'project' && !this.assertProjectWorkspaceForMutation()) {
      return 'invalid';
    }
    this.saving.set(true);
    this.error.set(null);
    try {
      await firstValueFrom(this.api.updateWorkflow(id, command, this.workspaceRoot(), activeScope));
      this.editDirty.set(false);
      await this.refreshWorkflows();
      await this.openDetail(id, this.selectedScope() ?? activeScope);
      return 'ok';
    } catch (err: unknown) {
      if (err instanceof HttpErrorResponse && err.status === 409) {
        const message = 'The file changed since it was loaded; reload before saving.';
        this.error.set(message);
        void this.errorDialog.displayError(err, message);
        return 'conflict';
      }
      if (err instanceof HttpErrorResponse && err.status === 422) {
        this.handleError(err, 'Workflow failed validation');
        return 'invalid';
      }
      this.handleError(err, 'Failed to save workflow');
      return 'invalid';
    } finally {
      this.saving.set(false);
    }
  }

  async customize(id: string, command: CustomizeWorkflowCommand = { targetScope: 'project', sourceScope: 'bundled' }): Promise<CustomizeWorkflowResponse | null> {
    if (command.targetScope === 'project' && !this.assertProjectWorkspaceForMutation()) {
      return null;
    }
    this.saving.set(true);
    this.error.set(null);
    try {
      // Both callers navigate to /workflows/:id/edit, whose route subscription
      // is the single detail-load authority. Refreshing the list and loading
      // the detail here as well made customize a six-request serial waterfall
      // (customize, list, detail, runs, then detail again after navigation).
      return await firstValueFrom(this.api.customizeWorkflow(id, command, this.workspaceRoot()));
    } catch (err: unknown) {
      this.handleError(err, 'Failed to customize workflow');
      return null;
    } finally {
      this.saving.set(false);
    }
  }

  /** Returns 'ok', 'conflict', or 'invalid' for routing-only saves. */
  async patchRouting(id: string, scope: WritableWorkflowScope, patch: WorkflowRoutingPatch): Promise<'ok' | 'conflict' | 'invalid'> {
    if (scope === 'project' && !this.assertProjectWorkspaceForMutation()) {
      return 'invalid';
    }
    this.saving.set(true);
    this.error.set(null);
    try {
      await firstValueFrom(this.api.patchWorkflowRouting(id, scope, patch, this.workspaceRoot()));
      await this.refreshWorkflows();
      await this.openDetail(id, scope);
      return 'ok';
    } catch (err: unknown) {
      if (err instanceof HttpErrorResponse && err.status === 409) {
        const message = 'The file changed since it was loaded; reload before saving.';
        this.error.set(message);
        void this.errorDialog.displayError(err, message);
        return 'conflict';
      }
      if (err instanceof HttpErrorResponse && err.status === 422) {
        this.handleError(err, 'Workflow failed validation');
        return 'invalid';
      }
      if (err instanceof HttpErrorResponse && err.status === 400) {
        this.handleError(err, 'Invalid routing update');
        return 'invalid';
      }
      this.handleError(err, 'Failed to save routing');
      return 'invalid';
    } finally {
      this.saving.set(false);
    }
  }

  async remove(id: string, scope: WritableWorkflowScope, revealEffective = false): Promise<boolean> {
    if (scope === 'project' && !this.assertProjectWorkspaceForMutation()) {
      return false;
    }
    this.error.set(null);
    try {
      await firstValueFrom(this.api.deleteWorkflow(id, scope, this.workspaceRoot()));
      await this.refreshWorkflows();
      if (this.selectedId() === id) {
        if (revealEffective) {
          await this.openDetail(id);
        } else {
          this.selected.set(null);
          this.selectedId.set(null);
          this.selectedScope.set(null);
        }
      }
      return true;
    } catch (err: unknown) {
      this.handleError(err, 'Failed to delete workflow');
      return false;
    }
  }

  /** Resolves a workspace path (from the target-workspace picker) to its `.ralph-workspace` root. */
  resolveWorkspaceRoot(path: string): string | undefined {
    return this.workspaceSelector.workspaces().find((w) => w.path === path)?.workspaceRoot;
  }

  async start(id: string, command: StartWorkflowCommand, workspaceRootOverride?: string): Promise<StartWorkflowResponse | null> {
    if (!workspaceRootOverride && !this.assertProjectWorkspaceForMutation()) {
      return null;
    }
    if (this.triggeringIds().has(id)) {
      return null;
    }
    this.triggeringIds.update((current) => new Set([...current, id]));
    try {
      const response = await firstValueFrom(this.api.startWorkflow(id, command, workspaceRootOverride ?? this.workspaceRoot()));
      if (this.selectedId() === id) {
        this.ensureRunsPolling(id, true);
        await this.loadRuns(id);
      }
      return response;
    } catch (err: unknown) {
      this.handleError(err, 'Failed to start workflow');
      return null;
    } finally {
      this.triggeringIds.update((current) => {
        const next = new Set(current);
        next.delete(id);
        return next;
      });
    }
  }

  isTriggering(id: string): boolean {
    return this.triggeringIds().has(id);
  }

  async cancelRun(runId: string): Promise<boolean> {
    try {
      await firstValueFrom(this.api.cancelRun(runId, this.workspaceRoot()));
      await this.loadRunStatus(runId);
      return true;
    } catch (err: unknown) {
      this.handleError(err, 'Failed to cancel run');
      return false;
    }
  }

  async resumeRun(runId: string): Promise<boolean> {
    try {
      await firstValueFrom(this.api.resumeRun(runId, this.workspaceRoot()));
      await this.loadRunStatus(runId);
      return true;
    } catch (err: unknown) {
      this.handleError(err, 'Failed to resume run');
      return false;
    }
  }

  async resetRun(runId: string, command: { stage?: string; all?: boolean }): Promise<boolean> {
    try {
      await firstValueFrom(this.api.resetRun(runId, command, this.workspaceRoot()));
      await this.loadRunStatus(runId);
      return true;
    } catch (err: unknown) {
      this.handleError(err, 'Failed to reset run');
      return false;
    }
  }

  async respondAction(runId: string, command: RespondActionCommand): Promise<boolean> {
    try {
      await firstValueFrom(this.api.respondRunAction(runId, command, this.workspaceRoot()));
      await this.loadRunStatus(runId);
      return true;
    } catch (err: unknown) {
      this.handleError(err, 'Failed to respond to the pending action');
      return false;
    }
  }

  async listRunActions(runId: string): Promise<unknown> {
    try {
      return await firstValueFrom(this.api.listRunActions(runId, this.workspaceRoot()));
    } catch (err: unknown) {
      this.handleError(err, 'Failed to load pending actions');
      return [];
    }
  }

  async loadModels(runtimeId: string): Promise<readonly ModelDescriptor[]> {
    const cached = this.modelsByRuntime().get(runtimeId);
    if (cached) {
      return cached;
    }
    try {
      const models = await firstValueFrom(this.api.listModels(runtimeId, this.workspaceRoot()));
      this.modelsByRuntime.update((map) => {
        const next = new Map(map);
        next.set(runtimeId, models);
        return next;
      });
      return models;
    } catch {
      return [];
    }
  }

  formatErrorDetails(err: unknown): string {
    if (!(err instanceof HttpErrorResponse)) {
      return '';
    }
    const body = err.error as ApiErrorBody | undefined;
    if (body?.diagnostics) {
      return body.diagnostics;
    }
    if (body?.error) {
      return body.error;
    }
    return '';
  }

  private handleError(err: unknown, fallback: string): void {
    const details = this.formatErrorDetails(err);
    const message = details ? `${fallback}: ${details}` : fallback;
    this.error.set(message);
    void this.errorDialog.displayError(err ?? message, fallback);
  }

  /** Clears client-side live-run state when the registry no longer has this run. */
  private evictStaleRun(runId: string): void {
    this.evictedRunIds.add(runId);
    this.stopRunStatusPolling();
    const statusRun = this.runStatus()?.run as { id?: unknown; runId?: unknown } | undefined;
    const boundId =
      typeof statusRun?.id === 'string'
        ? statusRun.id
        : typeof statusRun?.runId === 'string'
          ? statusRun.runId
          : null;
    if (!boundId || boundId === runId) {
      this.runStatus.set(null);
    }
    const filtered = this.runs().filter((run) => run.runId !== runId);
    if (filtered.length !== this.runs().length) {
      this.runs.set(filtered);
    }
    const workflowId = this.selectedId();
    if (workflowId) {
      this.ensureRunsPolling(workflowId);
    }
  }
}
