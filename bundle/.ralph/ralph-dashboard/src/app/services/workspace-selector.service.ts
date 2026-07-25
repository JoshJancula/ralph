import { Injectable, inject, signal, computed } from '@angular/core';
import { toObservable } from '@angular/core/rxjs-interop';
import { finalize, map } from 'rxjs/operators';
import { ApiService, WorkspaceRegistry } from './api.service';

@Injectable({
  providedIn: 'root',
})
export class WorkspaceSelectorService {
  private readonly apiService = inject(ApiService);
  private static readonly SELECTED_WORKSPACE_KEY = 'ralph-workspace-selected';

  readonly workspaces = signal<WorkspaceRegistry[]>([]);
  readonly selectedWorkspacePath = signal<string | null>(this.loadSelectedWorkspace());
  readonly isGlobalMode = computed(() => {
    const workspaces = this.workspaces();
    return workspaces.length > 1;
  });
  readonly shouldShowSwitcher = computed(() => {
    const workspaces = this.workspaces();
    return workspaces.length >= 2;
  });
  readonly displayWorkspaces = computed(() => {
    return this.workspaces().map((ws) => ({
      path: ws.path,
      display: this.getDisplayName(ws.path),
      exists: ws.exists,
    }));
  });

  private workspacesLoadInflight = false;
  private workspacesLoadCallbacks: Array<(() => void) | undefined> = [];

  constructor() {
    toObservable(this.workspaces).subscribe(() => {
      const current = this.selectedWorkspacePath();
      const workspaces = this.workspaces();

      if (workspaces.length === 0) {
        this.clearSelectedWorkspace();
      } else if (workspaces.length === 1 && current === null) {
        this.selectedWorkspacePath.set(workspaces[0].path);
      } else if (current && !workspaces.some((w) => w.path === current)) {
        this.clearSelectedWorkspace();
      }
    });
  }

  loadWorkspaces(onLoaded?: () => void): void {
    this.workspacesLoadCallbacks.push(onLoaded);
    if (this.workspacesLoadInflight) {
      return;
    }
    this.workspacesLoadInflight = true;
    this.apiService
      .fetchWorkspaces()
      .pipe(
        map((workspaces) => workspaces.filter((ws) => ws.exists)),
        finalize(() => {
          this.workspacesLoadInflight = false;
          const callbacks = this.workspacesLoadCallbacks;
          this.workspacesLoadCallbacks = [];
          for (const cb of callbacks) {
            cb?.();
          }
        }),
      )
      .subscribe({
        next: (workspaces) => this.workspaces.set(workspaces),
        error: () => this.workspaces.set([]),
      });
  }

  selectWorkspace(path: string | null): void {
    this.selectedWorkspacePath.set(path);
    if (path === null) {
      this.removeStoredSelection();
    } else {
      window.localStorage?.setItem?.(WorkspaceSelectorService.SELECTED_WORKSPACE_KEY, path);
    }
  }

  private clearSelectedWorkspace(): void {
    this.selectedWorkspacePath.set(null);
    this.removeStoredSelection();
  }

  private removeStoredSelection(): void {
    if (typeof window === 'undefined') {
      return;
    }
    window.localStorage?.removeItem?.(WorkspaceSelectorService.SELECTED_WORKSPACE_KEY);
  }

  private loadSelectedWorkspace(): string | null {
    if (typeof window === 'undefined') {
      return null;
    }

    return window.localStorage?.getItem?.(WorkspaceSelectorService.SELECTED_WORKSPACE_KEY) ?? null;
  }

  private getDisplayName(path: string): string {
    return path.split('/').pop() || path;
  }

  getWorkspaceForMetricPath(metricPath: string): string | null {
    const workspaces = this.workspaces();
    for (const ws of workspaces) {
      if (metricPath.startsWith(ws.path)) {
        return ws.path;
      }
    }
    return null;
  }
}
