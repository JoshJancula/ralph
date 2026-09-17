import { Injectable, inject, signal } from '@angular/core';
import { beginInventoryFetch, isAbortError } from '../utils/request-lifecycle';
import { RequestLifecycleService } from './request-lifecycle.service';
import { TasksSchedulesService, type DashboardTask } from './tasks-schedules.service';

const DEFAULT_STATUSES = ['backlog', 'ready', 'in_progress', 'review', 'blocked', 'completed', 'discarded'];

function cacheKey(workspaceRoot?: string): string {
  return workspaceRoot?.trim() || '__default__';
}

@Injectable({ providedIn: 'root' })
export class TasksInventoryStore {
  private readonly api = inject(TasksSchedulesService);
  private readonly requestLifecycle = inject(RequestLifecycleService);

  static readonly SLOT = 'tasks-inventory';

  private readonly tasksByKey = new Map<string, DashboardTask[]>();
  private readonly statusesByKey = new Map<string, string[]>();
  private readonly loadedKeys = new Set<string>();

  readonly tasks = signal<DashboardTask[]>([]);
  readonly statuses = signal<string[]>([]);
  readonly loading = signal(false);
  readonly hasLoadedOnce = signal(false);
  readonly error = signal<unknown>(null);

  /** Clear cached inventory (used by tests and workspace teardown). */
  reset(): void {
    this.tasksByKey.clear();
    this.statusesByKey.clear();
    this.loadedKeys.clear();
    this.tasks.set([]);
    this.statuses.set([]);
    this.loading.set(false);
    this.hasLoadedOnce.set(false);
    this.error.set(null);
    this.requestLifecycle.cancel(TasksInventoryStore.SLOT);
  }

  /** Restore the last successful payload for this workspace without fetching. */
  hydrate(workspaceRoot?: string): void {
    const key = cacheKey(workspaceRoot);
    if (!this.tasksByKey.has(key)) {
      return;
    }
    this.tasks.set(this.tasksByKey.get(key)!);
    this.statuses.set(this.statusesByKey.get(key) ?? []);
    this.hasLoadedOnce.set(this.loadedKeys.has(key));
    this.loading.set(false);
  }

  /** Show cached rows when present, then merge in a fresh API response. */
  refresh(workspaceRoot?: string): void {
    const key = cacheKey(workspaceRoot);
    const hadCache = this.loadedKeys.has(key);

    if (this.tasksByKey.has(key)) {
      this.tasks.set(this.tasksByKey.get(key)!);
      this.statuses.set(this.statusesByKey.get(key) ?? [...DEFAULT_STATUSES]);
      this.hasLoadedOnce.set(hadCache);
    }

    beginInventoryFetch(hadCache, (value) => this.loading.set(value));
    if (!hadCache) {
      this.error.set(null);
    }

    const handle = this.requestLifecycle.start(TasksInventoryStore.SLOT, { workspaceRoot: key });

    this.api.listTasks(workspaceRoot).subscribe({
      next: (tasks) => {
        if (!this.requestLifecycle.isCurrent(handle)) {
          return;
        }
        this.tasksByKey.set(key, tasks);
        this.tasks.set(tasks);
        this.loadedKeys.add(key);
        this.hasLoadedOnce.set(true);
        this.loading.set(false);
        this.error.set(null);
      },
      error: (err) => {
        if (!this.requestLifecycle.isCurrent(handle) || isAbortError(err)) {
          return;
        }
        if (!hadCache) {
          this.error.set(err);
        }
        this.hasLoadedOnce.set(true);
        this.loading.set(false);
      },
    });

    this.api.listTaskStatuses().subscribe({
      next: (statuses) => {
        if (!this.requestLifecycle.isCurrent(handle)) {
          return;
        }
        this.statusesByKey.set(key, statuses);
        this.statuses.set(statuses);
      },
      error: () => {
        if (!this.requestLifecycle.isCurrent(handle)) {
          return;
        }
        const fallback = [...DEFAULT_STATUSES];
        this.statusesByKey.set(key, fallback);
        this.statuses.set(fallback);
      },
    });
  }
}
