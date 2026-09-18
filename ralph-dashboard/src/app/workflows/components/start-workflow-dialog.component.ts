import { Component, computed, HostListener, inject, input, output, signal } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { TasksSchedulesService, type DashboardTask } from '../../services/tasks-schedules.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { WorkflowsFacade } from '../workflows.facade';
import { ModelSelectComponent } from './model-select.component';

const RUNTIME_OPTIONS = ['cursor', 'claude', 'codex', 'opencode', 'antigravity'] as const;

/**
 * Start dialog supports either a queued dashboard task (which preserves the
 * task snapshot and lifecycle) or an ad-hoc task text run.
 */
@Component({
  selector: 'ralph-start-workflow-dialog',
  standalone: true,
  imports: [FormsModule, ModelSelectComponent],
  template: `
    @if (open()) {
      <div class="hub-modal-backdrop" (click)="close()" (keydown.escape)="close()">
        <div
          class="dialog hub-modal-panel hub-modal-panel--compact start-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="Start workflow"
          data-testid="start-dialog"
          (click)="$event.stopPropagation()"
          (keydown.escape)="close()"
        >
          <header class="start-dialog-header">
            <h3 class="dialog-title">Start {{ workflowId() }}</h3>
          </header>

          @if (!confirming()) {
            <div class="start-dialog-body" data-testid="start-form-panel">
            @if (targetWorkspaces().length > 0) {
              <label class="field">
                <span>Target workspace</span>
                <select class="control" data-testid="start-workspace" [ngModel]="targetWorkspace()" name="targetWorkspace" (ngModelChange)="onTargetWorkspaceChange($event)">
                  @for (ws of targetWorkspaces(); track ws.path) {
                    <option [value]="ws.path">{{ ws.display }}{{ ws.exists ? '' : ' (missing)' }}</option>
                  }
                </select>
              </label>
              <p class="hint" data-testid="start-workspace-hint">Run sandbox: {{ resolvedProjectRoot() }}</p>
            }

            <label class="field">
              <span>Run</span>
              <select class="control" data-testid="start-source" [ngModel]="source()" name="source" (ngModelChange)="source.set($event)">
                <option value="queued">A queued task (ready or backlog)</option>
                <option value="adhoc">New ad-hoc task</option>
              </select>
            </label>

            @if (source() === 'queued') {
              <label class="field">
                <span>Queued task</span>
                <select class="control" data-testid="start-queued-task" [ngModel]="selectedTaskId()" name="queuedTask" (ngModelChange)="onQueuedTaskChange($event)" [disabled]="tasksLoading() || !readyTasks().length">
                  <option value="" disabled>{{ tasksLoading() ? 'Loading queued tasks…' : 'Select a queued task…' }}</option>
                  @for (queuedTask of readyTasks(); track queuedTask.id) {
                    <option [value]="queuedTask.id">{{ queuedTask.title }}</option>
                  }
                </select>
              </label>
              @if (!tasksLoading() && !readyTasks().length) {
                <p class="hint" data-testid="start-no-queued-tasks">No ready or backlog tasks are assigned to this workflow in the selected project. Choose New ad-hoc task to start one directly.</p>
              }
            } @else {
              <label class="field">
                <span>Task</span>
                <textarea class="control" rows="4" data-testid="start-task" [(ngModel)]="task" name="task" required placeholder="Describe what this run should accomplish…"></textarea>
              </label>
              @if (task().trim().length === 0) {
                <p class="error" data-testid="start-task-error">A task description is required.</p>
              }
            }

            <div class="field-row">
              <label class="field">
                <span>Runtime override</span>
                <select class="control" data-testid="start-runtime" [ngModel]="runtime()" name="runtime" (ngModelChange)="onRuntimeChange($event)">
                  <option value="">Auto (workflow default)</option>
                  @for (rt of runtimeOptions; track rt) {
                    <option [value]="rt">{{ rt }}</option>
                  }
                </select>
              </label>

              @if (runtime()) {
                <ralph-model-select data-testid="start-model" [runtime]="runtime()" [model]="model()" (modelChange)="model.set($event)" />
              } @else {
                <label class="field">
                  <span>Model override</span>
                  <input class="control" type="text" data-testid="start-model" value="" placeholder="inherit" disabled />
                </label>
              }
            </div>
            </div>

            <footer class="hub-modal-footer start-dialog-footer">
              <button type="button" class="btn btn-ghost" data-testid="start-cancel" (click)="close()">Cancel</button>
              <button type="button" class="btn btn-primary" data-testid="start-review" [disabled]="!canReview()" (click)="confirming.set(true)">
                Review
              </button>
            </footer>
          } @else {
            <div class="start-dialog-body start-review-panel" data-testid="start-review-panel">
            @if (targetWorkspaces().length > 0) {
              <p class="hint" data-testid="start-workspace-hint">Run sandbox: {{ resolvedProjectRoot() }}</p>
            }
            <p class="command-preview" data-testid="start-command-preview">{{ resolvedCommand() }}</p>
            </div>
            <footer class="hub-modal-footer start-dialog-footer">
              <button type="button" class="btn btn-ghost" data-testid="start-back" (click)="confirming.set(false)">Back</button>
              <button type="button" class="btn btn-primary" data-testid="start-confirm" [disabled]="starting()" (click)="confirmStart()">
                {{ starting() ? 'Starting…' : 'Confirm start' }}
              </button>
            </footer>
          }
        </div>
      </div>
    }
  `,
  styles: `
    .start-dialog {
      padding: 0;
      overflow: hidden;
      gap: 0;
    }
    .start-dialog-header {
      padding: 1.25rem 1.35rem 0.35rem;
    }
    .start-dialog-body {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
      padding: 0.65rem 1.35rem 1rem;
    }
    .start-dialog-footer {
      margin: 0;
    }
    .dialog-title {
      margin: 0;
      font-size: var(--font-size-lg);
      font-family: var(--monospace-font);
      color: var(--text-primary);
      font-weight: 650;
    }
    .field-row {
      display: flex;
      gap: 0.6rem;
    }
    .field-row > * {
      flex: 1;
      min-width: 0;
    }
    .field {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      font-size: var(--font-size-sm);
      color: var(--text-muted);
    }
    .field > span {
      font-size: var(--font-size-xs);
      font-weight: 600;
      letter-spacing: var(--letter-label);
      text-transform: uppercase;
    }
    .error {
      color: var(--danger);
      font-size: var(--font-size-xs);
      margin: 0;
    }
    .hint {
      color: var(--text-muted);
      font-size: var(--font-size-xs);
      font-family: var(--monospace-font);
      margin: 0;
      line-height: 1.4;
    }
    .command-preview {
      margin: 0;
      padding: var(--space-3);
      border: 1px solid var(--panel-border);
      border-radius: var(--radius-md);
      background: var(--code-bg, var(--surface-secondary));
      font-family: var(--monospace-font);
      font-size: var(--font-size-sm);
      white-space: pre-wrap;
      word-break: break-word;
      max-width: 100%;
      overflow-x: auto;
    }
  `,
})
export class StartWorkflowDialogComponent {
  private readonly facade = inject(WorkflowsFacade);
  private readonly router = inject(Router);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);
  private readonly tasksApi = inject(TasksSchedulesService);
  private returnFocusEl: HTMLElement | null = null;

  readonly workflowId = input.required<string>();
  readonly open = signal(false);
  readonly started = output<string | undefined>();

  readonly runtimeOptions = RUNTIME_OPTIONS;
  readonly task = signal('');
  readonly source = signal<'queued' | 'adhoc'>('queued');
  readonly readyTasks = signal<readonly DashboardTask[]>([]);
  readonly selectedTaskId = signal('');
  readonly tasksLoading = signal(false);
  readonly runtime = signal('');
  readonly model = signal('');
  readonly targetWorkspace = signal<string | null>(null);
  readonly confirming = signal(false);
  readonly starting = signal(false);

  /** Every known workspace, so the operator can send this run at a different sandbox than whatever the sidebar happens to have selected. */
  readonly targetWorkspaces = computed(() => this.workspaceSelector.displayWorkspaces());
  readonly selectedTask = computed(() => this.readyTasks().find((task) => task.id === this.selectedTaskId()) ?? null);
  readonly canReview = computed(() => this.source() === 'queued' ? Boolean(this.selectedTask()) : this.task().trim().length > 0);

  readonly resolvedProjectRoot = computed(() => {
    const path = this.targetWorkspace();
    if (!path) {
      return '(dashboard root)';
    }
    return this.workspaceSelector.workspaces().find((w) => w.path === path)?.projectRoot ?? path;
  });

  readonly resolvedCommand = computed(() => {
    if (this.source() === 'queued') {
      const selected = this.selectedTask();
      if (!selected) {
        return 'Select a ready queued task before launching.';
      }
      const lines = [
        `Launch queued task: ${selected.title}`,
        `The dashboard will snapshot the task and start workflow ${this.workflowId()}.`,
      ];
      if (this.runtime()) {
        lines.push(`Runtime override: ${this.runtime()}`);
      }
      if (this.runtime() && this.model()) {
        lines.push(`Model override: ${this.model()}`);
      }
      return lines.join('\n');
    }
    const parts = ['ralph', 'workflow', 'start', this.workflowId(), '--task', JSON.stringify(this.task().trim()), '--yes'];
    if (this.runtime()) {
      parts.push('--runtime', this.runtime());
    }
    if (this.runtime() && this.model()) {
      parts.push('--model', this.model());
    }
    return parts.join(' ');
  });

  @HostListener('document:keydown', ['$event'])
  onDocumentKeyDown(event: KeyboardEvent): void {
    if (!this.open()) {
      return;
    }
    if (event.key === 'Escape') {
      event.preventDefault();
      this.close();
    }
  }

  onRuntimeChange(value: string): void {
    this.runtime.set(value);
    if (!value) {
      this.model.set('');
    }
  }

  onQueuedTaskChange(taskId: string): void {
    this.selectedTaskId.set(taskId);
    const queued = this.readyTasks().find((task) => task.id === taskId);
    this.runtime.set(queued?.runtime ?? '');
    this.model.set(queued?.model ?? '');
  }

  launch(): void {
    this.returnFocusEl = (document.activeElement as HTMLElement) ?? null;
    this.task.set('');
    this.source.set('queued');
    this.readyTasks.set([]);
    this.selectedTaskId.set('');
    this.runtime.set('');
    this.model.set('');
    const workspaces = this.targetWorkspaces();
    const current = this.workspaceSelector.selectedWorkspacePath();
    if (current && workspaces.some((ws) => ws.path === current)) {
      this.targetWorkspace.set(current);
    } else if (workspaces.length === 1) {
      this.targetWorkspace.set(workspaces[0].path);
    } else {
      this.targetWorkspace.set(null);
    }
    this.confirming.set(false);
    this.open.set(true);
    void this.loadReadyTasks();
  }

  async loadReadyTasks(): Promise<void> {
    const path = this.targetWorkspace();
    if (!path) return;
    this.tasksLoading.set(true);
    try {
      const workspaceRoot = this.facade.resolveWorkspaceRoot(path);
      const tasks = await firstValueFrom(this.tasksApi.listTasks(workspaceRoot));
      this.readyTasks.set(tasks.filter((task) => task.workflowId === this.workflowId() && (task.status === 'ready' || task.status === 'backlog')));
    } finally {
      this.tasksLoading.set(false);
    }
  }

  onTargetWorkspaceChange(path: string): void {
    this.targetWorkspace.set(path);
    this.selectedTaskId.set('');
    this.readyTasks.set([]);
    void this.loadReadyTasks();
  }

  close(): void {
    this.open.set(false);
    this.confirming.set(false);
    const el = this.returnFocusEl;
    this.returnFocusEl = null;
    if (el && typeof el.focus === 'function') {
      setTimeout(() => el.focus(), 0);
    }
  }

  async confirmStart(): Promise<void> {
    this.starting.set(true);
    try {
      const path = this.targetWorkspace();
      if (!path) {
        this.facade.requireProjectSelection();
        return;
      }
      const workspaceRootOverride = this.facade.resolveWorkspaceRoot(path);
      if (this.source() === 'queued') {
        const selected = this.selectedTask();
        if (!selected) return;
        const launchOverrides = {
          ...(this.runtime() ? { runtime: this.runtime() } : {}),
          ...(this.runtime() && this.model() ? { model: this.model() } : {}),
        };
        const response = await firstValueFrom(this.tasksApi.launchTask(selected.id, workspaceRootOverride, launchOverrides));
        this.open.set(false);
        this.confirming.set(false);
        this.started.emit(response.attempt.runId);
        if (response.attempt.runId) void this.router.navigate(['/workflows', 'runs', response.attempt.runId]);
        return;
      }
      const response = await this.facade.start(this.workflowId(), {
        task: this.task().trim(),
        runtime: this.runtime() || undefined,
        model: this.runtime() && this.model() ? this.model() : undefined,
      }, workspaceRootOverride);
      this.open.set(false);
      this.confirming.set(false);
      this.started.emit(response?.runId);
      if (response?.runId) {
        void this.router.navigate(['/workflows', 'runs', response.runId]);
      }
    } finally {
      this.starting.set(false);
    }
  }
}
