import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { beginInventoryFetch, shouldShowRouteSkeleton } from '../utils/request-lifecycle';
import { FormsModule } from '@angular/forms';
import { RouteLoadStateComponent } from '../components/route-load-state/route-load-state.component';
import { ErrorDialogService } from '../services/error-dialog.service';
import { WorkflowsApi } from '../workflows/workflows-api.service';
import type { WorkflowListItem } from '../workflows/workflow.types';
import {
  TasksSchedulesService,
  type DashboardSchedule,
  type DashboardSchedulePatch,
} from '../services/tasks-schedules.service';

const PRESETS = [
  { label: 'Every hour', cron: '0 * * * *' },
  { label: 'Every weekday morning', cron: '0 9 * * 1-5' },
  { label: 'Every weekday afternoon', cron: '0 14 * * 1-5' },
  { label: 'Daily', cron: '0 9 * * *' },
  { label: 'Weekly (Monday)', cron: '0 9 * * 1' },
];

/** Draft-only sentinel for the built-in task worker; the API stores it as `worker`, never as a workflow id. */
const TASK_WORKER = '__task-worker__';
const AUTO = 'auto';

/** Mirrors the server's RESERVED_WORKER_STATUSES: running work, the columns the worker parks results in, and closed work. */
const RESERVED_WORKER_STATUSES = ['in_progress', 'review', 'blocked', 'completed', 'discarded'];

type Draft = {
  name: string;
  runs: string;
  brief: string;
  mode: 'one' | 'all';
  maxConcurrent: number;
  status: string;
  preset: string;
  cron: string;
  timezone: string;
  enabled: boolean;
};

const emptyDraft = (): Draft => ({
  name: '',
  runs: TASK_WORKER,
  brief: '',
  mode: 'one',
  maxConcurrent: 3,
  status: 'ready',
  preset: PRESETS[1].cron,
  cron: PRESETS[1].cron,
  timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  enabled: true,
});

@Component({
  selector: 'ralph-schedules-page',
  standalone: true,
  imports: [FormsModule, RouteLoadStateComponent],
  template: `
    <main class="page hub-page" data-testid="schedules-page">
      <header class="page-header">
        <div>
          <p class="eyebrow">Automation</p>
          <h1 class="page-title">Schedules</h1>
          <p class="page-lede">
            Schedules run only while the dashboard server is online. The task worker pulls tasks from a status column
            and runs each with its own workflow; tasks without one are routed by triage first. A workflow schedule runs
            one workflow with fixed instructions. Schedules never exceed their limit and pause themselves after repeated failures.
          </p>
        </div>
        <div class="header-actions">
          <button type="button" class="btn btn-primary" (click)="openCreate()">New schedule</button>
        </div>
      </header>

      @if (notice()) {
        <div class="notice-banner" role="status">
          <span>{{ notice() }}</span>
        </div>
      }

      <ralph-route-load-state
        [loading]="showLoadingSkeleton()"
        [errorDetail]="error()"
        [columns]="2"
        [rowCount]="4"
        (retry)="load()"
      />

      @if (!showLoadingSkeleton() && !error()) {
        <section
          class="schedule-section"
          [attr.aria-label]="schedules().length ? schedules().length + ' schedules' : 'Schedules'"
        >
          @if (!schedules().length) {
            <div class="empty-state" data-testid="schedules-empty">
              <p class="empty-title">No schedules yet</p>
              <p class="empty-hint">Start a task worker to keep your queue moving, or run a workflow on an interval.</p>
              <div class="empty-actions">
                <button type="button" class="btn btn-primary" (click)="openCreate()">Create schedule</button>
              </div>
            </div>
          } @else {
            <div class="schedules-grid">
              @for (schedule of schedules(); track schedule.id) {
                <article class="schedule-card surface-card" [class.is-disabled]="!schedule.enabled">
                  <div class="card-main">
                    <div class="badges-row">
                      <span
                        class="status-pill"
                        [class.pill-enabled]="schedule.enabled"
                        [class.pill-paused]="!schedule.enabled"
                      >
                        {{ schedule.enabled ? 'Enabled' : 'Paused' }}
                      </span>
                      <span class="meta-pill">{{ kindLabel(schedule) }}</span>
                      @if (runningLabel(schedule)) {
                        <span class="running-pill">
                          <span class="pulsing-dot" aria-hidden="true"></span>
                          {{ runningLabel(schedule) }}
                        </span>
                      }
                    </div>

                    <h3 class="schedule-name">{{ schedule.name }}</h3>

                    <div class="meta-specs">
                      <span class="spec-item">
                        <span class="spec-label">Target:</span>
                        <b>{{ sourceLabel(schedule) }}</b>
                      </span>
                      <span class="spec-item">
                        <span class="spec-label">Timing:</span>
                        <code>{{ schedule.cron }}</code>
                      </span>
                      <span class="spec-item">
                        <span class="spec-label">Zone:</span>
                        <span>{{ schedule.timezone }}</span>
                      </span>
                    </div>

                    <div class="schedule-timing">
                      <span class="timing-detail">
                        <b>Next:</b> {{ schedule.nextRunAt || 'calculating' }}
                      </span>
                      <span class="timing-divider">·</span>
                      <span class="timing-detail">
                        <b>Last:</b> {{ schedule.lastRunAt || 'never' }}
                      </span>
                    </div>

                    @if (!schedule.worker && schedule.activeAttempt?.summary && !runningLabel(schedule)) {
                      <div class="result-box">
                        <span class="result-title">Last result ({{ schedule.activeAttempt?.outcome || schedule.activeAttempt?.status }}):</span>
                        <p class="result-summary">{{ schedule.activeAttempt?.summary }}</p>
                      </div>
                    }

                    @if (schedule.lastError) {
                      <div class="error-banner" role="alert">
                        <span class="error-title">Failure notice:</span>
                        <p class="error-text">{{ schedule.lastError }}</p>
                      </div>
                    }
                  </div>

                  <div class="card-actions">
                    <button type="button" class="btn btn-ghost" (click)="openEdit(schedule)">Edit</button>
                    <button type="button" class="btn btn-ghost" (click)="toggle(schedule)">
                      {{ schedule.enabled ? 'Pause' : 'Enable' }}
                    </button>
                    <button
                      type="button"
                      class="btn btn-primary"
                      [disabled]="atLimit(schedule)"
                      (click)="run(schedule)"
                    >
                      Run now
                    </button>
                  </div>
                </article>
              }
            </div>
          }
        </section>
      }

      @if (editing()) {
        <div class="hub-modal-backdrop" (click)="close()">
          <section
            class="schedule-modal hub-modal-panel"
            role="dialog"
            aria-modal="true"
            aria-labelledby="schedule-dialog-title"
            (click)="$event.stopPropagation()"
          >
            <header class="modal-header">
              <div>
                <p class="eyebrow">{{ editingId() ? 'Edit schedule' : 'New schedule' }}</p>
                <h2 id="schedule-dialog-title" class="modal-title">Automate work</h2>
              </div>
              <button type="button" class="close-btn" aria-label="Close" (click)="close()">×</button>
            </header>

            <form (ngSubmit)="save()" class="schedule-form hub-modal-body">
              <section class="hub-panel-card">
                <div class="section-head">
                  <h3 class="section-legend">What runs</h3>
                  <p class="section-hint">Task worker or a single workflow on a fixed brief.</p>
                </div>
              <label class="field-label">
                <span>Name</span>
                <input
                  type="text"
                  name="name"
                  class="form-control"
                  [(ngModel)]="draft.name"
                  placeholder="Morning queue"
                  required
                />
              </label>

              <label class="field-label">
                <span>Runs</span>
                <select name="runs" class="form-control" [(ngModel)]="draft.runs" required>
                  <option [value]="taskWorker">Task worker (built-in): works tasks with each task's workflow</option>
                  @for (workflow of scheduleWorkflows(); track workflow.id) {
                    <option [value]="workflow.id">{{ workflow.id }} — {{ workflow.overview }}</option>
                  }
                </select>
              </label>

              @if (!workflows().length) {
                <p class="form-help">Loading available workflows…</p>
              }

              @if (draft.runs === taskWorker) {
                <div class="form-grid">
                  <label class="field-label">
                    <span>Work on</span>
                    <select name="mode" class="form-control" [(ngModel)]="draft.mode">
                      <option value="one">One task at a time</option>
                      <option value="all">All matching tasks, up to a limit</option>
                    </select>
                  </label>
                  @if (draft.mode === 'all') {
                    <label class="field-label">
                      <span>At most at once</span>
                      <input
                        name="maxConcurrent"
                        type="number"
                        min="1"
                        max="10"
                        class="form-control"
                        [(ngModel)]="draft.maxConcurrent"
                      />
                    </label>
                  }
                </div>

                <label class="field-label">
                  <span>Only tasks with status</span>
                  <select name="status" class="form-control" [(ngModel)]="draft.status" required>
                    @for (status of pullableStatuses(); track status) {
                      <option [value]="status">{{ label(status) }}</option>
                    }
                  </select>
                </label>

                <p class="form-help">
                  Oldest tasks go first. Each runs with its assigned workflow; tasks without one, or set to Auto, go
                  through triage first and return to this status with the recommended workflow for a later pass. Failed runs
                  also return here, until they have failed three times.
                  @if (draft.mode === 'all') {
                    Parallel tasks share this project's working tree unless their workflow isolates itself.
                  }
                </p>

                <label class="field-label">
                  <div class="label-with-sub">
                    <span>Extra instructions</span>
                    <small class="label-aside">Optional. Added to every task this worker runs.</small>
                  </div>
                  <textarea
                    name="brief"
                    class="form-control"
                    [(ngModel)]="draft.brief"
                    rows="3"
                    placeholder="For example: keep changes small and open a draft PR."
                  ></textarea>
                </label>
              } @else {
                <label class="field-label">
                  <div class="label-with-sub">
                    <span>Instructions</span>
                    <small class="label-aside">Sent with every run</small>
                  </div>
                  <textarea
                    name="brief"
                    class="form-control"
                    [(ngModel)]="draft.brief"
                    rows="4"
                    placeholder="For example: summarize overnight CI failures."
                    required
                  ></textarea>
                </label>
              }
              </section>

              <section class="hub-panel-card">
                <div class="section-head">
                  <h3 class="section-legend">When</h3>
                  <p class="section-hint">Cron schedule and timezone for the next run.</p>
                </div>
              <div class="form-grid">
                <label class="field-label">
                  <span>Schedule</span>
                  <select name="preset" class="form-control" [(ngModel)]="draft.preset" (ngModelChange)="applyPreset()">
                    @for (option of presets; track option.cron) {
                      <option [value]="option.cron">{{ option.label }}</option>
                    }
                    <option value="custom">Custom schedule…</option>
                  </select>
                </label>

                <label class="field-label">
                  <span>Timezone</span>
                  <input
                    type="text"
                    name="zone"
                    class="form-control"
                    [(ngModel)]="draft.timezone"
                    placeholder="America/New_York"
                    required
                  />
                </label>
              </div>

              @if (draft.preset === 'custom') {
                <label class="field-label">
                  <div class="label-with-sub">
                    <span>Custom cron expression</span>
                    <small class="label-aside">Five fields: minute hour day month weekday</small>
                  </div>
                  <input
                    type="text"
                    name="cron"
                    class="form-control"
                    [(ngModel)]="draft.cron"
                    placeholder="0 9 * * 1-5"
                    required
                  />
                </label>
              }

              <div class="preview-box hub-nested-panel">
                <div class="preview-head">
                  <span class="preview-title">Timing Preview</span>
                  <code class="preview-expr">{{ draft.cron }} · {{ draft.timezone }}</code>
                  <button type="button" class="btn btn-ghost btn-sm" (click)="preview()">Preview next runs</button>
                </div>
                @if (previewTimes().length) {
                  <ul class="preview-list">
                    @for (time of previewTimes(); track time) {
                      <li class="preview-item">{{ time }}</li>
                    }
                  </ul>
                }
              </div>
              </section>

              <footer class="hub-modal-footer">
                <button type="button" class="btn btn-ghost" (click)="close()">Cancel</button>
                <button type="submit" class="btn btn-primary" [disabled]="!canSave()">
                  {{ editingId() ? 'Save changes' : 'Create schedule' }}
                </button>
              </footer>
            </form>
          </section>
        </div>
      }
    </main>
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
    }

    .page {
      display: flex;
      flex-direction: column;
      flex: 1;
      min-height: 0;
      max-width: 100%;
      overflow-x: hidden;
      overflow-y: auto;
    }

    .header-actions {
      display: flex;
      align-items: center;
      gap: var(--space-2);
    }

    .notice-banner {
      padding: 0.75rem 1rem;
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      background: var(--surface);
      color: var(--text-primary);
      font-size: var(--font-size-sm);
      margin-bottom: var(--space-4);
      border-left: 3px solid var(--accent);
    }

    .schedule-section {
      display: flex;
      flex-direction: column;
      gap: var(--space-4);
      margin-top: var(--space-2);
    }

    .schedules-grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: var(--space-3);
    }

    .schedule-card {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: var(--space-4);
      padding: 1.25rem 1.5rem;
    }

    .schedule-card:hover {
      border-color: var(--ion-color-step-300, #6e7681);
      box-shadow: 0 10px 28px rgba(0, 0, 0, 0.18);
    }

    .schedule-card.is-disabled {
      opacity: 0.75;
      background: var(--surface-muted, var(--surface));
    }

    .card-main {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
      flex: 1;
      min-width: 0;
    }

    .badges-row {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-wrap: wrap;
    }

    .status-pill {
      display: inline-flex;
      align-items: center;
      padding: 0.15rem 0.55rem;
      border-radius: 999px;
      font-size: var(--font-size-xs);
      font-weight: 600;
      letter-spacing: 0.02em;
      border: 1px solid transparent;
    }

    .pill-enabled {
      background: color-mix(in srgb, var(--success, #238636) 15%, transparent);
      color: var(--success, #3fb950);
      border-color: color-mix(in srgb, var(--success, #238636) 30%, transparent);
    }

    .pill-paused {
      background: var(--surface-muted);
      color: var(--text-muted);
      border-color: var(--border);
    }

    .meta-pill {
      display: inline-flex;
      align-items: center;
      padding: 0.15rem 0.55rem;
      border-radius: var(--radius-sm);
      border: 1px solid var(--border);
      background: var(--surface-secondary, var(--background));
      color: var(--text-muted);
      font-size: var(--font-size-xs);
      font-weight: 500;
    }

    .running-pill {
      display: inline-flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.15rem 0.55rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--accent) 15%, transparent);
      color: var(--accent);
      border: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
      font-size: var(--font-size-xs);
      font-weight: 600;
    }

    .pulsing-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: var(--accent);
      box-shadow: 0 0 0 0 color-mix(in srgb, var(--accent) 70%, transparent);
      animation: pulse 1.6s infinite ease-out;
    }

    @keyframes pulse {
      0% {
        transform: scale(0.95);
        box-shadow: 0 0 0 0 color-mix(in srgb, var(--accent) 70%, transparent);
      }
      70% {
        transform: scale(1);
        box-shadow: 0 0 0 6px transparent;
      }
      100% {
        transform: scale(0.95);
        box-shadow: 0 0 0 0 transparent;
      }
    }

    .schedule-name {
      margin: 0;
      font-size: 1.1rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .meta-specs {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 1.25rem;
      font-size: var(--font-size-sm);
      color: var(--text-primary);
    }

    .spec-item {
      display: inline-flex;
      align-items: center;
      gap: 0.35rem;
    }

    .spec-label {
      color: var(--text-muted);
      font-size: var(--font-size-xs);
      text-transform: uppercase;
      letter-spacing: var(--letter-label);
      font-weight: 600;
    }

    .spec-item code {
      font-family: var(--monospace-font);
      font-size: 0.85em;
      padding: 0.1rem 0.35rem;
      border-radius: var(--radius-sm);
      background: var(--surface-secondary, var(--background));
      border: 1px solid var(--border);
    }

    .schedule-timing {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      font-size: var(--font-size-xs);
      color: var(--text-muted);
    }

    .timing-divider {
      opacity: 0.5;
    }

    .result-box {
      margin-top: 0.35rem;
      padding: 0.6rem 0.85rem;
      border-radius: var(--radius-md);
      border: 1px solid var(--border);
      background: var(--surface-secondary, var(--background));
    }

    .result-title {
      display: block;
      font-size: var(--font-size-xs);
      font-weight: 600;
      color: var(--text-primary);
      margin-bottom: 0.2rem;
    }

    .result-summary {
      margin: 0;
      font-size: var(--font-size-xs);
      color: var(--text-muted);
      line-height: 1.4;
    }

    .error-banner {
      margin-top: 0.35rem;
      padding: 0.6rem 0.85rem;
      border-radius: var(--radius-md);
      border: 1px solid color-mix(in srgb, var(--danger, #f85149) 30%, transparent);
      background: color-mix(in srgb, var(--danger, #f85149) 10%, var(--surface));
      color: var(--danger, #f85149);
    }

    .error-title {
      display: block;
      font-size: var(--font-size-xs);
      font-weight: 700;
      margin-bottom: 0.2rem;
    }

    .error-text {
      margin: 0;
      font-size: var(--font-size-xs);
      white-space: pre-line;
      line-height: 1.4;
    }

    .card-actions {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-shrink: 0;
    }

    .schedule-modal {
      width: min(680px, 100%);
    }

    .schedule-modal .modal-header {
      padding: 1.5rem 1.75rem 1rem;
      flex-shrink: 0;
    }

    .schedule-form.hub-modal-body {
      padding-top: 0;
    }

    .modal-header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 1rem;
    }

    .modal-title {
      margin: 0;
      font-size: 1.35rem;
      color: var(--text-primary);
    }

    .close-btn {
      border: none;
      background: transparent;
      color: var(--text-muted);
      font-size: 1.75rem;
      line-height: 1;
      padding: 0.2rem 0.4rem;
      border-radius: var(--radius-sm);
      cursor: pointer;
    }

    .close-btn:hover {
      color: var(--text-primary);
      background: var(--surface-hover);
    }

    .schedule-form {
      display: flex;
      flex-direction: column;
      gap: 1.15rem;
    }

    .form-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 0.75rem;
    }

    .form-help {
      margin: 0;
      font-size: var(--font-size-xs);
      color: var(--text-muted);
      line-height: 1.45;
    }

    .preview-box {
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
    }

    .preview-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      flex-wrap: wrap;
    }

    .preview-title {
      font-size: var(--font-size-xs);
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: var(--letter-label);
      color: var(--text-muted);
    }

    .preview-expr {
      font-family: var(--monospace-font);
      font-size: var(--font-size-xs);
      color: var(--text-primary);
    }

    .btn-sm {
      padding: 0.25rem 0.5rem;
      font-size: var(--font-size-xs);
      min-height: 28px;
    }

    .preview-list {
      margin: 0;
      padding: 0;
      list-style: none;
      display: grid;
      gap: 0.25rem;
    }

    .preview-item {
      font-family: var(--monospace-font);
      font-size: var(--font-size-xs);
      color: var(--text-muted);
    }

    .modal-footer {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 0.75rem;
      padding-top: 1.25rem;
      border-top: 1px solid var(--border);
    }

    @media (max-width: 768px) {
      .schedule-card {
        flex-direction: column;
        align-items: stretch;
      }

      .card-actions {
        justify-content: flex-start;
        flex-wrap: wrap;
      }

      .form-grid {
        grid-template-columns: 1fr;
      }

      .schedule-modal {
        width: 100%;
      }
    }
  `,
})
export class SchedulesPageComponent implements OnInit {
  private readonly api = inject(TasksSchedulesService);
  private readonly workflowsApi = inject(WorkflowsApi);
  private readonly errorDialog = inject(ErrorDialogService);

  readonly presets = PRESETS;
  readonly taskWorker = TASK_WORKER;

  readonly schedules = signal<DashboardSchedule[]>([]);
  readonly workflows = signal<readonly WorkflowListItem[]>([]);

  /** Auto routes individual tasks, so it is not offered as a schedulable workflow. */
  readonly scheduleWorkflows = computed(() => this.workflows().filter((w) => w.id !== AUTO));

  readonly statuses = signal<string[]>(['backlog', 'ready']);

  readonly pullableStatuses = computed(() => {
    const allowed = this.statuses().filter((s) => !RESERVED_WORKER_STATUSES.includes(s));
    const current = this.draftStatus();
    return current && !allowed.includes(current) && !RESERVED_WORKER_STATUSES.includes(current)
      ? [...allowed, current]
      : allowed;
  });

  private readonly draftStatus = signal('ready');

  readonly loading = signal(true);
  readonly hasLoadedOnce = signal(false);
  readonly showLoadingSkeleton = computed(() => shouldShowRouteSkeleton(this.loading(), this.hasLoadedOnce()));
  readonly error = signal<unknown>(null);
  readonly notice = signal('');
  readonly editing = signal(false);
  readonly editingId = signal<string | null>(null);
  readonly previewTimes = signal<string[]>([]);

  draft = emptyDraft();

  ngOnInit(): void {
    this.load();
    this.workflowsApi.listWorkflows().subscribe({ next: (x) => this.workflows.set(x) });
    this.api.listTaskStatuses().subscribe({ next: (x) => this.statuses.set(x) });
  }

  label(s: string): string {
    return s.replaceAll('_', ' ');
  }

  kindLabel(s: DashboardSchedule): string {
    if (!s.worker) return 'Workflow';
    return s.worker.mode === 'one' ? 'Task worker, one at a time' : `Task worker, up to ${s.worker.maxConcurrent} at once`;
  }

  sourceLabel(s: DashboardSchedule): string {
    return s.worker ? `Tasks in ${this.label(s.worker.status)}` : s.workflowId;
  }

  runningCount(s: DashboardSchedule): number {
    return s.worker
      ? (s.activeTaskIds?.length ?? 0)
      : s.activeAttempt?.status === 'launching' || s.activeAttempt?.status === 'running'
        ? 1
        : 0;
  }

  runningLabel(s: DashboardSchedule): string {
    const n = this.runningCount(s);
    if (!n) return '';
    return s.worker ? `${n} task${n === 1 ? '' : 's'} running` : 'Run in progress';
  }

  atLimit(s: DashboardSchedule): boolean {
    const n = this.runningCount(s);
    if (!s.worker) return n > 0;
    return s.worker.mode === 'one' ? n > 0 : n >= s.worker.maxConcurrent;
  }

  canSave(): boolean {
    const d = this.draft;
    if (!d.runs) return false;
    return d.runs === TASK_WORKER ? !!d.status && !RESERVED_WORKER_STATUSES.includes(d.status) : !!d.brief.trim();
  }

  openCreate(): void {
    this.editingId.set(null);
    this.draft = emptyDraft();
    this.draftStatus.set(this.draft.status);
    this.editing.set(true);
  }

  openEdit(s: DashboardSchedule): void {
    this.editingId.set(s.id);
    this.draft = {
      ...emptyDraft(),
      name: s.name,
      runs: s.worker ? TASK_WORKER : s.workflowId,
      brief: s.brief || '',
      mode: s.worker?.mode ?? 'one',
      maxConcurrent: s.worker?.maxConcurrent ?? 3,
      status: s.worker?.status ?? 'ready',
      cron: s.cron,
      timezone: s.timezone,
      enabled: s.enabled,
      preset: PRESETS.some((x) => x.cron === s.cron) ? s.cron : 'custom',
    };
    this.draftStatus.set(this.draft.status);
    this.editing.set(true);
  }

  close(): void {
    this.editing.set(false);
    this.previewTimes.set([]);
  }

  applyPreset(): void {
    if (this.draft.preset !== 'custom') {
      this.draft.cron = this.draft.preset;
    }
  }

  preview(): void {
    this.api.preview(this.draft.cron, this.draft.timezone).subscribe({
      next: (x) => this.previewTimes.set(x.times),
      error: (err) => {
        void this.errorDialog.displayError(err, 'Check the timezone and custom cron.');
      },
    });
  }

  load(): void {
    beginInventoryFetch(this.hasLoadedOnce(), (value) => this.loading.set(value));
    this.api.listSchedules().subscribe({
      next: (x) => {
        this.schedules.set(x);
        this.hasLoadedOnce.set(true);
        this.loading.set(false);
      },
      error: (err) => {
        this.error.set(err);
        this.hasLoadedOnce.set(true);
        this.loading.set(false);
      },
    });
  }

  save(): void {
    if (!this.canSave()) return;
    const d = this.draft;
    const isWorker = d.runs === TASK_WORKER;
    const body: DashboardSchedulePatch = {
      name: d.name,
      cron: d.cron,
      timezone: d.timezone,
      enabled: d.enabled,
      brief: d.brief,
      workflowId: isWorker ? '' : d.runs,
      worker: isWorker ? { mode: d.mode, maxConcurrent: d.maxConcurrent, status: d.status } : null,
    };
    const id = this.editingId();
    const request = id ? this.api.patchSchedule(id, body) : this.api.createSchedule(body);
    request.subscribe({
      next: () => {
        this.close();
        this.load();
      },
      error: (e) => {
        void this.errorDialog.displayError(e, e?.error?.error || 'Use a valid timezone and custom cron when supplied.');
      },
    });
  }

  toggle(x: DashboardSchedule): void {
    this.api.patchSchedule(x.id, { enabled: !x.enabled }).subscribe({
      next: () => this.load(),
    });
  }

  run(x: DashboardSchedule): void {
    this.notice.set('');
    this.api.runSchedule(x.id).subscribe({
      next: () => this.load(),
      error: (e) => {
        const message = e?.error?.error ? `Not started: ${e.error.error}` : 'Unable to run schedule.';
        this.notice.set(message);
        void this.errorDialog.displayError(e, message);
        this.load();
      },
    });
  }
}
