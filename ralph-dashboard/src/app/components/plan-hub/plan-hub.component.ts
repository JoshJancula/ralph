import {
  ChangeDetectionStrategy,
  Component,
  OnInit,
  OnDestroy,
  inject,
  effect,
  input,
  signal,
  computed,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService, PlanInventoryItem, PlanInventoryResponse } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { RequestLifecycleService } from '../../services/request-lifecycle.service';
import { PlanListRowComponent } from './plan-list-row.component';
import { RouteLoadStateComponent } from '../route-load-state/route-load-state.component';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { Subject } from 'rxjs';
import { debounceTime, distinctUntilChanged, takeUntil } from 'rxjs/operators';
import { beginInventoryFetch, isAbortError, shouldShowRouteSkeleton } from '../../utils/request-lifecycle';
import { markInventoryUsable } from '../../utils/perf-diagnostics';

type SortField = 'name' | 'status' | 'project' | 'lastActivity';
type SortOrder = 'asc' | 'desc';
type StatusFilter = '' | 'active' | 'completed' | 'waiting';
type TypeFilter = '' | 'leaf' | 'generated-control' | 'supplied' | 'workflow-derived';

interface QueryState {
  search: string;
  status: StatusFilter;
  type: TypeFilter;
  sort: SortField;
  sortOrder: SortOrder;
  pageSize: number;
  cursor?: string;
}

@Component({
  selector: 'ralph-plan-hub',
  standalone: true,
  imports: [CommonModule, FormsModule, RouterLink, PlanListRowComponent, RouteLoadStateComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="plan-hub hub-page">
      <div class="header page-header">
        <div>
          <h1 class="page-title">Plans</h1>
          <p class="page-lede">Inventory of discovered plans, progress, and latest activity.</p>
        </div>
      </div>

      <div class="toolbar hub-toolbar plans-toolbar">
        <div class="plans-filter-row">
          <select [(ngModel)]="queryState().status" (change)="onStatusChange()" class="filter-select" aria-label="Filter by status">
            <option value="">All statuses</option>
            <option value="active">Active</option>
            <option value="completed">Completed</option>
            <option value="waiting">Waiting</option>
          </select>
          <select [(ngModel)]="queryState().type" (change)="onTypeChange()" class="filter-select" aria-label="Filter by type">
            <option value="">All types</option>
            <option value="leaf">Leaf</option>
            <option value="generated-control">Generated</option>
            <option value="supplied">Supplied</option>
            <option value="workflow-derived">Workflow</option>
          </select>
          @if (hasFilters()) {
            <button type="button" class="btn btn-ghost plans-clear-filters" (click)="clearFilters()">Clear filters</button>
          }
        </div>
        <div class="plans-search-row">
          <input
            type="search"
            class="search-input"
            data-testid="plans-search"
            placeholder="Search plans"
            [(ngModel)]="queryState().search"
            (ngModelChange)="onSearchChange($event)"
            aria-label="Search plans"
          />
        </div>
      </div>

      @if (currentResponse()?.activityDiscoveryError; as activityError) {
        <p class="activity-discovery-error" role="status">{{ activityError }} Existing plan inventory is still shown.</p>
      }

      <ralph-route-load-state
        [loading]="showLoadingSkeleton()"
        [errorDetail]="error()"
        [columns]="5"
        [rowCount]="8"
        (retry)="fetchPlans()"
      />

      @if (!showLoadingSkeleton() && !error()) {
        @if (visibleItems().length === 0) {
          <div class="empty-state" data-testid="plans-empty">
            @if (queryState().search || queryState().status || queryState().type) {
              <p class="empty-title">No plans match your filters</p>
              <p class="empty-hint">Clear search or filters to see the full inventory.</p>
              <div class="empty-actions">
                <button type="button" class="btn btn-secondary" (click)="clearFilters()">Clear filters</button>
              </div>
            } @else {
              <p class="empty-title">No plans found</p>
              <p class="empty-hint">Ralph discovers leaf plans in this workspace. Create one from the terminal, then return here.</p>
              <div class="empty-actions">
                <a class="btn btn-secondary" routerLink="/home">Back to Home</a>
              </div>
            }
          </div>
        } @else {
          <div class="plan-table data-table" data-testid="plans-inventory" role="table" aria-label="Plans">
            <div class="plan-table-header data-table-header" role="row">
              <div class="col-name data-table-priority" role="columnheader">
                <button type="button" class="sort-button" (click)="setSortField('name')">
                  Name
                  @if (queryState().sort === 'name') {
                    <span class="sort-indicator">{{ queryState().sortOrder === 'asc' ? 'ASC' : 'DESC' }}</span>
                  }
                </button>
              </div>
              <div class="col-status data-table-priority" role="columnheader">Status</div>
              <div class="col-progress data-table-priority" role="columnheader">Progress</div>
              <div class="col-project data-table-secondary data-table-tablet-hide" role="columnheader">Project</div>
              <div class="col-activity data-table-secondary" role="columnheader">
                <button type="button" class="sort-button" (click)="setSortField('lastActivity')">
                  Last activity
                  @if (queryState().sort === 'lastActivity') {
                    <span class="sort-indicator">{{ queryState().sortOrder === 'asc' ? 'ASC' : 'DESC' }}</span>
                  }
                </button>
              </div>
              <div class="col-actions" role="columnheader"><span class="sr-only">Actions</span></div>
            </div>
            @for (item of visibleItems(); track item.id) {
              <ralph-plan-list-row [item]="item" (openPlan)="onOpenPlan($event)" (runPlan)="onRunPlan($event)" (stopPlan)="onStopPlan($event)" />
            }
          </div>

          @if (pageInfo().total > queryState().pageSize) {
            <div class="pagination">
              <button type="button" class="btn btn-secondary" (click)="previousPage()" [disabled]="pageNumber() === 1">
                Previous
              </button>
              <span class="pagination-info">Page {{ pageNumber() }} · {{ pageRangeLabel() }} of {{ pageInfo().total }}</span>
              <button type="button" class="btn btn-secondary" (click)="nextPage()" [disabled]="!pageInfo().hasMore">
                Next
              </button>
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
    .plan-hub {
      background: transparent;
    }

    .plans-toolbar {
      flex-direction: column;
      align-items: stretch;
      gap: var(--space-3);
    }

    .plans-filter-row {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: var(--space-3);
      width: 100%;
    }

    .plans-filter-row .filter-select {
      flex: 1 1 0;
      min-width: 9rem;
      width: auto;
    }

    .plans-clear-filters {
      flex: 0 0 auto;
      margin-left: auto;
    }

    .plans-search-row {
      width: 100%;
    }

    .plans-search-row .search-input {
      width: 100%;
    }
    .plan-table {
      display: flex;
      flex-direction: column;
      border: 1px solid color-mix(in srgb, var(--border) 90%, transparent);
      border-radius: var(--radius-lg);
      overflow: hidden;
    }
    .plan-table-header {
      display: grid;
      grid-template-columns: minmax(0, 2.2fr) 7.5rem minmax(6.5rem, 1fr) minmax(0, 1fr) 7.5rem auto;
      gap: var(--space-4);
      padding: 0.7rem 0.9rem;
      background: var(--table-header-bg);
      border-bottom: 1px solid color-mix(in srgb, var(--border) 88%, transparent);
      font-weight: 600;
      font-size: 0.75rem;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    .col-name {
      grid-column: 1;
    }
    .col-status {
      grid-column: 2;
    }
    .col-progress {
      grid-column: 3;
    }
    .col-project {
      grid-column: 4;
    }
    .col-activity {
      grid-column: 5;
    }
    .col-actions {
      grid-column: 6;
    }
    .sort-button {
      background: none;
      border: none;
      color: var(--text-muted);
      font-weight: 600;
      font-size: var(--font-size-sm);
      text-transform: uppercase;
      letter-spacing: var(--letter-label);
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: var(--space-2);
      padding: 0;
      min-width: 0;
    }
    .sort-button:hover {
      color: var(--text-primary);
    }
    .sort-indicator {
      font-size: var(--font-size-xs);
      opacity: 0.6;
    }
    @media (max-width: 720px) {
      .plans-filter-row {
        flex-direction: column;
        align-items: stretch;
      }

      .plans-filter-row .filter-select {
        width: 100%;
      }

      .plans-clear-filters {
        margin-left: 0;
        align-self: flex-start;
      }
    }

    @media (max-width: 1024px) {
      .plan-table-header {
        grid-template-columns: minmax(0, 1.6fr) 7.5rem minmax(6.5rem, 1fr) 7.5rem auto;
      }
    }
    @media (max-width: 720px) {
      .plan-table-header {
        display: none;
      }
    }
  `,
})
export class PlanHubComponent implements OnInit, OnDestroy {
  readonly paneActive = input(false);

  private apiService = inject(ApiService);
  private navService = inject(NavService);
  private workspaceSelector = inject(WorkspaceSelectorService);
  private requestLifecycle = inject(RequestLifecycleService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);
  private destroy$ = new Subject<void>();
  private searchSubject$ = new Subject<string>();
  private static readonly SLOT = 'plans-index';

  queryState = signal<QueryState>({
    search: '',
    status: '',
    type: '',
    sort: 'lastActivity',
    sortOrder: 'desc',
    pageSize: 20,
  });

  currentResponse = signal<PlanInventoryResponse | null>(null);
  loading = signal(false);
  readonly hasLoadedOnce = signal(false);
  readonly showLoadingSkeleton = computed(() => shouldShowRouteSkeleton(this.loading(), this.hasLoadedOnce()));
  error = signal<unknown>(null);
  pageNumber = signal(1);
  private cursors: Array<string | undefined> = [undefined];

  pageInfo = computed(() => {
    const resp = this.currentResponse();
    return resp?.pageInfo ?? { hasMore: false, total: 0 };
  });

  visibleItems = computed(() => {
    const resp = this.currentResponse();
    return resp?.items ?? [];
  });

  private initialized = false;
  private readonly reloadNonce = signal(0);

  constructor() {
    effect((onCleanup) => {
      if (!this.paneActive()) {
        return;
      }
      this.workspaceSelector.selectedWorkspacePath();
      this.reloadNonce();
      if (!this.initialized) {
        return;
      }
      this.fetchPlans();
      const timer = window.setInterval(() => this.fetchPlans(), 30_000);
      onCleanup(() => window.clearInterval(timer));
    });
  }

  ngOnInit(): void {
    this.route.queryParams.pipe(takeUntil(this.destroy$)).subscribe((params) => {
      const search = params['search'] ?? '';
      const status = (params['status'] ?? '') as StatusFilter;
      const type = (params['type'] ?? '') as TypeFilter;
      const sort = (params['sort'] ?? 'lastActivity') as SortField;
      const sortOrder = (params['sortOrder'] ?? 'desc') as SortOrder;
      const current = this.queryState();

      this.queryState.set({
        search,
        status,
        type,
        sort,
        sortOrder,
        pageSize: 20,
        cursor: undefined,
      });
      this.resetPagination();
      this.initialized = true;
      this.reloadNonce.update((n) => n + 1);
    });

    this.searchSubject$
      .pipe(
        debounceTime(300),
        distinctUntilChanged(),
        takeUntil(this.destroy$),
      )
      .subscribe((search) => {
        const current = this.queryState();
        this.queryState.set({ ...current, search, cursor: undefined });
        this.resetPagination();
        this.reloadNonce.update((n) => n + 1);
        this.updateQueryParams();
      });
  }

  private updateQueryParams(): void {
    const query = this.queryState();
    const params: Record<string, string> = {};

    if (query.search) {
      params['search'] = query.search;
    }
    if (query.status) {
      params['status'] = query.status;
    }
    if (query.type) {
      params['type'] = query.type;
    }
    if (query.sort !== 'lastActivity') {
      params['sort'] = query.sort;
    }
    if (query.sortOrder !== 'desc') {
      params['sortOrder'] = query.sortOrder;
    }

    this.router.navigate([], { relativeTo: this.route, queryParams: params, queryParamsHandling: 'merge' });
  }

  private resetPagination(): void {
    this.cursors = [undefined];
    this.pageNumber.set(1);
  }

  ngOnDestroy(): void {
    this.requestLifecycle.cancel(PlanHubComponent.SLOT);
    this.destroy$.next();
    this.destroy$.complete();
  }

  fetchPlans(): void {
    const query = this.queryState();
    const handle = this.requestLifecycle.start(PlanHubComponent.SLOT, {
      project: this.workspaceSelector.selectedWorkspacePath(),
      search: query.search,
      status: query.status,
      type: query.type,
      sort: query.sort,
      sortOrder: query.sortOrder,
      cursor: query.cursor,
      pageSize: query.pageSize,
    });

    beginInventoryFetch(this.hasLoadedOnce(), (value) => this.loading.set(value));
    this.error.set(null);

    this.apiService
      .fetchPlanIndex(
        {
          search: query.search || undefined,
          status: query.status || undefined,
          type: query.type || undefined,
          projectRoot: this.workspaceSelector.selectedWorkspacePath() ?? undefined,
          allProjects: this.workspaceSelector.selectedWorkspacePath() === null,
          pageSize: query.pageSize,
          cursor: query.cursor,
        },
        { signal: handle.signal },
      )
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (resp) => {
          if (!this.requestLifecycle.isCurrent(handle)) {
            return;
          }
          this.currentResponse.set(resp);
          this.hasLoadedOnce.set(true);
          this.loading.set(false);
          markInventoryUsable('plans');
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

  onSearchChange(value: string): void {
    this.searchSubject$.next(value);
  }

  onStatusChange(): void {
    const current = this.queryState();
    this.queryState.set({ ...current, cursor: undefined });
    this.resetPagination();
    this.reloadNonce.update((n) => n + 1);
    this.updateQueryParams();
  }

  onTypeChange(): void {
    const current = this.queryState();
    this.queryState.set({ ...current, cursor: undefined });
    this.resetPagination();
    this.reloadNonce.update((n) => n + 1);
    this.updateQueryParams();
  }

  hasFilters(): boolean {
    const query = this.queryState();
    return Boolean(query.search || query.status || query.type);
  }

  clearFilters(): void {
    const current = this.queryState();
    this.queryState.set({
      ...current,
      search: '',
      status: '',
      type: '',
      cursor: undefined,
    });
    this.resetPagination();
    this.reloadNonce.update((n) => n + 1);
    this.updateQueryParams();
  }

  setSortField(field: SortField): void {
    const current = this.queryState();
    if (current.sort === field) {
      current.sortOrder = current.sortOrder === 'asc' ? 'desc' : 'asc';
    } else {
      current.sort = field;
      current.sortOrder = 'asc';
    }
    this.queryState.set({ ...current, cursor: undefined });
    this.resetPagination();
    this.reloadNonce.update((n) => n + 1);
    this.updateQueryParams();
  }

  nextPage(): void {
    const resp = this.currentResponse();
    if (resp?.pageInfo.cursor) {
      const current = this.queryState();
      const nextPage = this.pageNumber() + 1;
      this.cursors[nextPage - 1] = resp.pageInfo.cursor;
      this.queryState.set({ ...current, cursor: resp.pageInfo.cursor });
      this.pageNumber.set(nextPage);
      this.reloadNonce.update((n) => n + 1);
    }
  }

  previousPage(): void {
    const currentPage = this.pageNumber();
    if (currentPage <= 1) return;
    const previousPage = currentPage - 1;
    const current = this.queryState();
    this.queryState.set({ ...current, cursor: this.cursors[previousPage - 1] });
    this.pageNumber.set(previousPage);
    this.reloadNonce.update((n) => n + 1);
  }

  pageRangeLabel(): string {
    const total = this.pageInfo().total;
    if (total === 0) return '0';
    const start = (this.pageNumber() - 1) * this.queryState().pageSize + 1;
    const end = Math.min(start + this.visibleItems().length - 1, total);
    return `${start}–${end}`;
  }

  onOpenPlan(item: PlanInventoryItem): void {
    this.workspaceSelector.selectWorkspace(item.projectRoot);
    const fileName = item.path.endsWith('.md') ? item.path : `${item.path}.md`;
    void this.router.navigate(['/plan-detail', fileName], {
      queryParams: { projectRoot: item.projectRoot },
    });
  }

  onRunPlan(item: PlanInventoryItem): void {
    this.apiService.runLeafPlan(item.path, item.projectRoot).subscribe({ next: () => this.fetchPlans() });
  }

  onStopPlan(item: PlanInventoryItem): void {
    this.apiService.stopLeafPlan(item.path, item.projectRoot).subscribe({ next: () => this.fetchPlans() });
  }
}
