import {
  Component,
  OnDestroy,
  inject,
  effect,
  input,
  signal,
  computed,
  ChangeDetectionStrategy,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { Subject } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import { WorkflowsApi } from '../../workflows/workflows-api.service';
import { RunListItem } from '../../workflows/workflow.types';
import { RouteLoadStateComponent } from '../route-load-state/route-load-state.component';
import { RequestLifecycleService } from '../../services/request-lifecycle.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { beginInventoryFetch, isAbortError, shouldShowRouteSkeleton } from '../../utils/request-lifecycle';
import { markInventoryUsable } from '../../utils/perf-diagnostics';

type StatusFilter = '' | 'active' | 'waiting' | 'failed' | 'completed';
type ExecutionFilter = '' | 'workflow' | 'leaf-plan';
type SortField = 'createdAt' | 'state';
type SortOrder = 'asc' | 'desc';

interface QueryState {
  status: StatusFilter;
  execution: ExecutionFilter;
  task: string;
  sort: SortField;
  sortOrder: SortOrder;
}

const RUNS_PAGE_SIZE = 25;

@Component({
  selector: 'ralph-runs-hub',
  standalone: true,
  imports: [CommonModule, FormsModule, RouterLink, RouteLoadStateComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="runs-hub hub-page">
      <div class="header page-header">
        <div>
          <h1 class="page-title">Runs</h1>
          <p class="page-lede">Live, waiting, completed, and failed workflow and leaf-plan executions.</p>
        </div>
      </div>

      <div class="toolbar hub-toolbar runs-toolbar">
        <div class="runs-filter-row">
          <select [(ngModel)]="queryState().status" (change)="onStatusChange()" class="filter-select" aria-label="Filter by status">
            <option value="">All statuses</option>
            <option value="active">Active</option>
            <option value="waiting">Waiting</option>
            <option value="failed">Failed</option>
            <option value="completed">Completed</option>
          </select>
          <select
            [(ngModel)]="queryState().execution"
            (change)="onExecutionChange()"
            class="filter-select"
            aria-label="Filter by execution type"
          >
            <option value="">All types</option>
            <option value="workflow">Workflows</option>
            <option value="leaf-plan">Leaf plans</option>
          </select>
          <select [(ngModel)]="queryState().sort" (change)="onSortChange()" class="filter-select" aria-label="Sort by">
            <option value="createdAt">Most recent</option>
            <option value="state">State</option>
          </select>
          @if (hasActiveFilters()) {
            <button type="button" class="btn btn-ghost runs-clear-filters" (click)="clearFilters()">Clear filters</button>
          }
        </div>
        <div class="runs-search-row">
          <input
            type="search"
            [(ngModel)]="queryState().task"
            (input)="onTaskSearchChange()"
            class="search-input"
            data-testid="runs-task-search"
            placeholder="Search by task"
            aria-label="Search runs by task"
          />
        </div>
      </div>

      @if (skippedWorkspaces() > 0) {
        <p class="runs-aggregation-warning" data-testid="runs-skipped-workspaces" role="status">
          {{ skippedWorkspaces() }} registered workspace{{ skippedWorkspaces() === 1 ? '' : 's' }} skipped because the workspace state is unavailable.
        </p>
      }
      @if (originatingWorkspace()) {
        <p class="runs-originating-workspace" data-testid="runs-originating-workspace" role="status">
          Workspace: <span>{{ originatingWorkspace() }}</span>
        </p>
      }

      <ralph-route-load-state
        [loading]="showLoadingSkeleton()"
        [errorDetail]="error()"
        [columns]="6"
        [rowCount]="8"
        (retry)="loadRuns()"
      />

      @if (showLoadingSkeleton()) {
        <p class="runs-loading-copy" data-testid="runs-loading" role="status">Loading workflow runs…</p>
      }

      @if (!showLoadingSkeleton() && !error()) {
        @if (visibleRuns().length === 0) {
          <div class="empty-state" data-testid="runs-empty">
            @if (hasActiveFilters()) {
              <p class="empty-title">No runs match your filter</p>
              <p class="empty-hint">Try another task search or status, or clear the filters to see every run in this workspace.</p>
              <div class="empty-actions">
                <button type="button" class="btn btn-secondary" (click)="clearFilters()">Clear filters</button>
              </div>
            } @else {
              <p class="empty-title">No runs found</p>
              <p class="empty-hint">Workflow runs appear here after you start a delivery shape.</p>
              <div class="empty-actions">
                <a class="btn btn-primary" routerLink="/workflows">Open workflows</a>
              </div>
            }
          </div>
        } @else {
          <div class="runs-table data-table" data-testid="runs-inventory" role="table" aria-label="Runs">
            <div class="runs-header data-table-header" role="row">
              <div class="col-status data-table-priority" role="columnheader">Status</div>
              <div class="col-type data-table-priority" role="columnheader">Type</div>
              <div class="col-name data-table-priority" role="columnheader">Run ID</div>
              <div class="col-workflow data-table-secondary" role="columnheader">Workflow</div>
              <div class="col-stage data-table-secondary" role="columnheader">Task</div>
              <div class="col-runtime data-table-secondary data-table-tablet-hide" role="columnheader">Source</div>
              <div class="col-elapsed data-table-secondary data-table-tablet-hide" role="columnheader">Elapsed</div>
              <div class="col-created data-table-secondary" role="columnheader">Created</div>
              <div class="col-expand" role="columnheader"><span class="sr-only">Details</span></div>
            </div>
            @for (run of pagedRuns(); track run.runId) {
              <div
                class="run-row data-table-row"
                [class.failed]="isFailed(run.state)"
                [class.waiting]="isWaiting(run.state)"
                [class.active]="isActive(run.state)"
                [class.is-expanded]="isRowExpanded(run.runId)"
                role="row"
              >
                <div class="col-status data-table-priority" role="cell">
                  <span class="status-badge status-text" [class]="run.state">{{ formatState(run.state) }}</span>
                </div>
                <div class="col-type data-table-priority" role="cell"><span class="runtime-text">{{ run.executionKind === 'leaf-plan' ? 'Leaf plan' : 'Workflow' }}</span></div>
                <div class="col-name data-table-priority" role="cell">
                  <a class="run-id" [routerLink]="getRunDetailLink(run)">{{ run.runId }}</a>
                </div>
                <div class="col-workflow data-table-secondary" role="cell">
                  <span class="workflow-name">{{ run.workflowId || '-' }}</span>
                </div>
                <div class="col-stage data-table-secondary" role="cell">
                  <span class="stage-text">{{ run.task || '-' }}</span>
                </div>
                <div class="col-runtime data-table-secondary data-table-tablet-hide" role="cell">
                  <span class="runtime-text">{{ run.sourceKind || '-' }}</span>
                </div>
                <div class="col-elapsed data-table-secondary data-table-tablet-hide" role="cell">
                  <span class="elapsed-text">{{ formatElapsed(elapsedSeconds(run)) }}</span>
                </div>
                <div class="col-created data-table-secondary" role="cell">
                  <span class="created-text">{{ formatCreated(run.createdAt) }}</span>
                </div>
                <div class="col-expand" role="cell">
                  <button
                    type="button"
                    class="data-table-expand"
                    [attr.aria-expanded]="isRowExpanded(run.runId)"
                    [attr.aria-controls]="'run-detail-' + run.runId"
                    (click)="toggleRow(run.runId, $event)"
                  >
                    {{ isRowExpanded(run.runId) ? 'Less' : 'More' }}
                  </button>
                </div>
                <div class="data-table-detail" [attr.id]="'run-detail-' + run.runId" [hidden]="!isRowExpanded(run.runId)">
                  <dl>
                    <dt>Workflow</dt>
                    <dd>{{ run.workflowId || '-' }}</dd>
                    <dt>Task</dt>
                    <dd>{{ run.task || '-' }}</dd>
                    <dt>Workspace</dt>
                    <dd>{{ run.workspaceRoot || '-' }}</dd>
                    <dt>Source</dt>
                    <dd>{{ run.sourceKind || '-' }}</dd>
                    <dt>Elapsed</dt>
                    <dd>{{ formatElapsed(elapsedSeconds(run)) }}</dd>
                    <dt>Created</dt>
                    <dd>{{ formatCreated(run.createdAt) }}</dd>
                  </dl>
                </div>
              </div>
            }
          </div>
          @if (hasMorePages()) {
            <div class="pagination">
              <button type="button" class="btn btn-secondary" data-testid="runs-load-more" (click)="loadMore()">
                Load more
              </button>
              <span class="pagination-info">
                Showing {{ pagedRuns().length }} of {{ visibleRuns().length }}
              </span>
            </div>
          }
        }
      }
    </div>
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
    }

    .runs-hub {
      background: transparent;
    }

    .runs-toolbar {
      flex-direction: column;
      align-items: stretch;
      gap: var(--space-3);
    }

    .runs-filter-row {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: var(--space-3);
      width: 100%;
    }

    .runs-filter-row .filter-select {
      flex: 1 1 0;
      min-width: 9rem;
      width: auto;
    }

    .runs-clear-filters {
      flex: 0 0 auto;
      margin-left: auto;
    }

    .runs-search-row {
      width: 100%;
    }

    .runs-search-row .search-input {
      width: 100%;
    }

    .runs-loading-copy {
      margin: 0;
      color: var(--text-muted);
      font-size: var(--font-size-sm);
    }

    .runs-table {
      display: flex;
      flex-direction: column;
      gap: 0;
      border: 1px solid var(--panel-border);
      border-radius: var(--radius-lg);
      overflow: hidden;
      max-width: 100%;
    }

    .runs-header {
      display: grid;
      grid-template-columns: 90px minmax(0, 1.4fr) minmax(0, 1fr) minmax(0, 1.2fr) 90px 70px 100px 56px;
      gap: 0.5rem;
      padding: 0.7rem 1rem;
      background: var(--surface-secondary);
      border-bottom: 1px solid var(--panel-border);
      font-size: var(--font-size-xs);
      font-weight: 600;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: var(--letter-label);
    }

    .run-row {
      display: grid;
      grid-template-columns: 90px minmax(0, 1.4fr) minmax(0, 1fr) minmax(0, 1.2fr) 90px 70px 100px 56px;
      gap: 0.5rem;
      padding: 0.8rem 1rem;
      border-bottom: 1px solid var(--panel-border);
      background: var(--panel-bg);
      color: inherit;
      align-items: center;
      min-width: 0;
    }

    .run-row:last-child {
      border-bottom: none;
    }

    .run-row:hover {
      background: var(--surface-hover);
    }

    .run-row.failed {
      box-shadow: inset 3px 0 0 var(--error);
    }

    .run-row.waiting {
      box-shadow: inset 3px 0 0 var(--warning);
    }

    .run-row.active {
      box-shadow: inset 3px 0 0 var(--success);
    }

    .status-badge.running,
    .status-badge.queued {
      background: var(--success-bg, rgba(16, 185, 129, 0.1));
      color: var(--success);
    }

    .status-badge.waiting {
      background: var(--warning-bg, rgba(245, 158, 11, 0.1));
      color: var(--warning);
    }

    .status-badge.failed,
    .status-badge.stale,
    .status-badge.cancelled {
      background: var(--error-bg, rgba(220, 38, 38, 0.1));
      color: var(--error);
    }

    .status-badge.succeeded {
      background: var(--success-bg, rgba(16, 185, 129, 0.1));
      color: var(--success);
    }

    .run-id {
      font-family: var(--monospace-font);
      font-size: 0.85rem;
      color: var(--text-link, var(--accent));
      text-decoration: none;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      display: block;
      min-width: 0;
    }

    .run-id:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: var(--focus-ring-offset, 2px);
    }

    .workflow-name,
    .stage-text,
    .runtime-text,
    .elapsed-text,
    .created-text {
      font-size: 0.9rem;
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      display: block;
    }

    .workflow-name {
      color: var(--text-primary);
    }

    .stage-text {
      color: var(--text-primary);
    }

    .runtime-text,
    .elapsed-text,
    .created-text {
      color: var(--text-muted);
    }

    .col-expand {
      display: flex;
      justify-content: flex-end;
    }

    @media (max-width: 1024px) {
      .runs-header,
      .run-row {
        grid-template-columns: 90px minmax(0, 1.4fr) minmax(0, 1fr) minmax(0, 1.1fr) 90px 56px;
      }
    }

    @media (max-width: 720px) {
      .runs-filter-row {
        flex-direction: column;
        align-items: stretch;
      }

      .runs-filter-row .filter-select {
        width: 100%;
      }

      .runs-clear-filters {
        margin-left: 0;
        align-self: flex-start;
      }

      .runs-header {
        display: none;
      }

      .run-row {
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 0.45rem 0.75rem;
        padding: 0.85rem 0.9rem;
        white-space: normal;
      }

      .col-workflow,
      .col-stage,
      .col-runtime,
      .col-elapsed,
      .col-created {
        display: none;
      }

      .col-status {
        grid-column: 1;
      }

      .col-name {
        grid-column: 1;
      }

      .col-expand {
        grid-column: 2;
        grid-row: 1 / span 2;
        align-self: start;
      }
    }
  `,
})
export class RunsHubComponent implements OnDestroy {
  readonly paneActive = input(false);

  private readonly api = inject(WorkflowsApi);
  private readonly requestLifecycle = inject(RequestLifecycleService);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);
  private static readonly SLOT = 'runs-list';

  readonly queryState = signal<QueryState>({
      status: '',
      execution: '',
    task: '',
    sort: 'createdAt',
    sortOrder: 'desc',
  });

  readonly loading = signal(false);
  readonly hasLoadedOnce = signal(false);
  readonly showLoadingSkeleton = computed(() => shouldShowRouteSkeleton(this.loading(), this.hasLoadedOnce()));
  readonly error = signal<unknown>(null);
  readonly runs = signal<readonly RunListItem[]>([]);
  readonly originatingWorkspace = signal<string | null>(null);
  readonly skippedWorkspaces = signal(0);
  readonly pageSize = signal(RUNS_PAGE_SIZE);
  readonly expandedRows = signal<ReadonlySet<string>>(new Set());

  readonly visibleRuns = computed(() => {
    const all = this.runs();
    const status = this.queryState().status;
    const task = (this.queryState().task ?? '').trim().toLowerCase();

    const filtered = all.filter((run) => {
      if (status && this.mapState(run.state) !== status) return false;
      if (this.queryState().execution && (run.executionKind ?? 'workflow') !== this.queryState().execution) return false;
      if (!task) return true;
      // Run id is searchable alongside the task so a remembered id still resolves.
      return (run.task ?? '').toLowerCase().includes(task) || run.runId.toLowerCase().includes(task);
    });

    const sorted = [...filtered].sort((a, b) => {
      const field = this.queryState().sort;
      const order = this.queryState().sortOrder === 'asc' ? 1 : -1;

      if (field === 'createdAt') {
        const delta = new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime();
        return order * delta;
      }
      return order * a.state.localeCompare(b.state);
    });

    return sorted;
  });

  readonly pagedRuns = computed(() => this.visibleRuns().slice(0, this.pageSize()));

  readonly hasMorePages = computed(() => this.visibleRuns().length > this.pageSize());

  private readonly destroy$ = new Subject<void>();

  constructor() {
    effect(() => {
      if (!this.paneActive()) {
        return;
      }
      this.workspaceSelector.selectedWorkspacePath();
      this.queryState().status;
      this.loadRuns();
    });
  }

  ngOnDestroy(): void {
    this.requestLifecycle.cancel(RunsHubComponent.SLOT);
    this.destroy$.next();
    this.destroy$.complete();
  }

  loadRuns(): void {
    const handle = this.requestLifecycle.start(RunsHubComponent.SLOT, {
      project: this.workspaceSelector.selectedWorkspacePath(),
      status: this.queryState().status,
      sort: this.queryState().sort,
    });
    beginInventoryFetch(this.hasLoadedOnce(), (value) => this.loading.set(value));
    this.error.set(null);
    this.pageSize.set(RUNS_PAGE_SIZE);

    const filters: { workflow?: string; state?: string } = {};
    const status = this.queryState().status;
    if (status) {
      const stateValue = this.getStateFilter(status);
      if (stateValue) {
        filters.state = stateValue;
      }
    }

    this.api.listAllRuns(undefined, { signal: handle.signal }).pipe(takeUntil(this.destroy$)).subscribe({
      next: (response) => {
        if (!this.requestLifecycle.isCurrent(handle)) {
          return;
        }
        if ('runs' in response) {
          this.runs.set(response.runs);
          this.originatingWorkspace.set(response.workspaceRoot);
          this.skippedWorkspaces.set(response.skipped);
        } else {
          this.runs.set(response);
          this.originatingWorkspace.set(null);
          this.skippedWorkspaces.set(0);
        }
        this.hasLoadedOnce.set(true);
        this.loading.set(false);
        markInventoryUsable('runs');
      },
      error: (err) => {
        if (!this.requestLifecycle.isCurrent(handle) || isAbortError(err)) {
          return;
        }
        this.error.set(err);
        this.hasLoadedOnce.set(true);
        this.loading.set(false);
      },
    });
  }

  onStatusChange(): void {
    this.loadRuns();
  }
  onExecutionChange(): void { this.pageSize.set(RUNS_PAGE_SIZE); }

  onSortChange(): void {
    // No API call needed, just recompute with existing data
  }

  onTaskSearchChange(): void {
    // Task text already ships with every run row, so this filters in place.
    this.pageSize.set(RUNS_PAGE_SIZE);
  }

  hasActiveFilters(): boolean {
    return Boolean(this.queryState().status) || Boolean(this.queryState().execution) || (this.queryState().task ?? '').trim().length > 0;
  }

  clearFilters(): void {
    this.queryState.update((current) => ({ ...current, status: '', execution: '', task: '' }));
    this.loadRuns();
  }

  elapsedSeconds(run: RunListItem): number | undefined {
    const createdMs = Date.parse(run.createdAt);
    if (!Number.isFinite(createdMs)) {
      return undefined;
    }
    return Math.max(0, (Date.now() - createdMs) / 1000);
  }

  formatElapsed(seconds?: number): string {
    if (seconds === undefined) return '-';
    if (seconds < 60) return `${Math.round(seconds)}s`;
    if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
    return `${Math.round(seconds / 3600)}h`;
  }

  formatCreated(value: string): string {
    const ms = Date.parse(value);
    if (!Number.isFinite(ms)) {
      return value || '-';
    }
    return new Date(ms).toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  loadMore(): void {
    this.pageSize.update((size) => size + RUNS_PAGE_SIZE);
  }

  isRowExpanded(runId: string): boolean {
    return this.expandedRows().has(runId);
  }

  toggleRow(runId: string, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    this.expandedRows.update((current) => {
      const next = new Set(current);
      if (next.has(runId)) {
        next.delete(runId);
      } else {
        next.add(runId);
      }
      return next;
    });
  }

  private mapState(state: string): StatusFilter {
    if (state === 'waiting') return 'waiting';
    if (state === 'running' || state === 'queued') return 'active';
    if (state === 'failed' || state === 'stale' || state === 'cancelled') return 'failed';
    if (state === 'succeeded') return 'completed';
    return 'completed';
  }

  private getStateFilter(status: StatusFilter): string | undefined {
    if (status === 'active') return 'running,queued';
    if (status === 'waiting') return 'waiting';
    if (status === 'failed') return 'failed,stale,cancelled';
    if (status === 'completed') return 'succeeded';
    return undefined;
  }

  formatState(state: string): string {
    return state.charAt(0).toUpperCase() + state.slice(1);
  }

  isActive(state: string): boolean {
    const active = new Set(['running', 'queued']);
    return active.has(state);
  }

  isWaiting(state: string): boolean {
    return state === 'waiting';
  }

  isFailed(state: string): boolean {
    const failed = new Set(['failed', 'stale', 'cancelled']);
    return failed.has(state);
  }

  getRunDetailLink(run: RunListItem): string {
    if (run.executionKind === 'leaf-plan') return '/tasks';
    return `/workflows/runs/${run.runId}`;
  }
}
