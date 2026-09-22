import { Injectable, inject, signal, computed } from '@angular/core';
import { toObservable } from '@angular/core/rxjs-interop';
import { finalize, map } from 'rxjs/operators';
import { ApiService, WorkspaceRegistry } from './api.service';

export interface ProjectGroup {
  label: string;
  projects: ProjectItem[];
}

export interface ProjectItem {
  projectRoot: string;
  label: string;
  parentPath: string;
  isPinned: boolean;
  isRecent: boolean;
  exists: boolean;
}

@Injectable({
  providedIn: 'root',
})
export class WorkspaceSelectorService {
  private readonly apiService = inject(ApiService);
  private static readonly SELECTED_WORKSPACE_KEY = 'ralph-workspace-selected';
  private static readonly PINNED_PROJECTS_KEY = 'ralph-pinned-projects';
  private static readonly RECENT_PROJECTS_KEY = 'ralph-recent-projects';
  private static readonly RECENT_PROJECTS_MAX = 5;

  readonly workspaces = signal<WorkspaceRegistry[]>([]);
  /**
   * False until the first `loadWorkspaces()` response (success or error) has
   * landed. Consumers that pick a layout based on `workspaces().length`
   * (e.g. the sidebar's project-tree vs. legacy-root-list branch) must wait
   * for this before treating an empty list as "genuinely no workspaces" —
   * otherwise the sidebar renders the wrong layout for however long the
   * fetch takes and then swaps, which reads as the whole tree "jumping".
   */
  readonly hasLoadedOnce = signal(false);
  readonly selectedWorkspacePath = signal<string | null>(this.loadSelectedWorkspace());
  readonly pinnedProjects = signal<Set<string>>(this.loadPinnedProjects());
  readonly recentProjects = signal<string[]>(this.loadRecentProjects());

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

  readonly groupedProjects = computed(() => {
    const workspaces = this.workspaces();
    const pinned = this.pinnedProjects();
    const recent = this.recentProjects();

    const projectMap = new Map<string, ProjectItem>();

    for (const ws of workspaces) {
      projectMap.set(ws.projectRoot, {
        projectRoot: ws.projectRoot,
        label: ws.label,
        parentPath: this.getParentPath(ws.projectRoot),
        isPinned: pinned.has(ws.projectRoot),
        isRecent: recent.includes(ws.projectRoot),
        exists: ws.exists,
      });
    }

    return this.buildProjectGroups(Array.from(projectMap.values()));
  });

  readonly displayName = computed(() => {
    const selected = this.selectedWorkspacePath();
    if (!selected) return 'All projects';

    const workspaces = this.workspaces();
    const ws = workspaces.find((w) => w.projectRoot === selected);
    return ws ? ws.label : 'Unknown project';
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
        this.selectedWorkspacePath.set(workspaces[0].projectRoot);
      } else if (current && !workspaces.some((w) => w.projectRoot === current)) {
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
          this.hasLoadedOnce.set(true);
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

  selectWorkspace(projectRoot: string | null): void {
    this.selectedWorkspacePath.set(projectRoot);
    if (projectRoot === null) {
      this.removeStoredSelection();
    } else {
      window.localStorage?.setItem?.(WorkspaceSelectorService.SELECTED_WORKSPACE_KEY, projectRoot);
      this.recordRecentProject(projectRoot);
    }
  }

  togglePinnedProject(projectRoot: string): void {
    this.pinnedProjects.update((pinned) => {
      const next = new Set(pinned);
      if (next.has(projectRoot)) {
        next.delete(projectRoot);
      } else {
        next.add(projectRoot);
      }
      this.savePinnedProjects(next);
      return next;
    });
  }

  isPinnedProject(projectRoot: string): boolean {
    return this.pinnedProjects().has(projectRoot);
  }

  private recordRecentProject(projectRoot: string): void {
    this.recentProjects.update((recent) => {
      const next = recent.filter((p) => p !== projectRoot);
      next.unshift(projectRoot);
      return next.slice(0, WorkspaceSelectorService.RECENT_PROJECTS_MAX);
    });
    this.saveRecentProjects(this.recentProjects());
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

  private loadPinnedProjects(): Set<string> {
    if (typeof window === 'undefined') {
      return new Set();
    }

    try {
      const stored = window.localStorage?.getItem?.(WorkspaceSelectorService.PINNED_PROJECTS_KEY);
      return stored ? new Set(JSON.parse(stored)) : new Set();
    } catch {
      return new Set();
    }
  }

  private savePinnedProjects(pinned: Set<string>): void {
    if (typeof window === 'undefined') {
      return;
    }

    try {
      window.localStorage?.setItem?.(
        WorkspaceSelectorService.PINNED_PROJECTS_KEY,
        JSON.stringify(Array.from(pinned))
      );
    } catch {
      // Ignore localStorage errors
    }
  }

  private loadRecentProjects(): string[] {
    if (typeof window === 'undefined') {
      return [];
    }

    try {
      const stored = window.localStorage?.getItem?.(WorkspaceSelectorService.RECENT_PROJECTS_KEY);
      return stored ? JSON.parse(stored) : [];
    } catch {
      return [];
    }
  }

  private saveRecentProjects(recent: string[]): void {
    if (typeof window === 'undefined') {
      return;
    }

    try {
      window.localStorage?.setItem?.(
        WorkspaceSelectorService.RECENT_PROJECTS_KEY,
        JSON.stringify(recent)
      );
    } catch {
      // Ignore localStorage errors
    }
  }

  private getDisplayName(path: string): string {
    return path.split('/').pop() || path;
  }

  private getParentPath(projectRoot: string): string {
    const parts = projectRoot.split('/');
    if (parts.length <= 1) return '';
    return parts.slice(0, -1).join('/');
  }

  private buildProjectGroups(projects: ProjectItem[]): ProjectGroup[] {
    const groups: ProjectGroup[] = [];
    const pinned = projects.filter((p) => p.isPinned);
    const recent = projects.filter((p) => p.isRecent && !p.isPinned);
    const all = projects.filter((p) => !p.isPinned && !p.isRecent);

    if (pinned.length > 0) {
      groups.push({
        label: 'Pinned',
        projects: pinned.sort((a, b) => a.label.localeCompare(b.label)),
      });
    }

    if (recent.length > 0) {
      groups.push({
        label: 'Recent',
        projects: recent,
      });
    }

    groups.push({
      label: 'All projects',
      projects: all.sort((a, b) => a.label.localeCompare(b.label)),
    });

    return groups;
  }

  getHasDuplicateNames(): boolean {
    const labels = new Set<string>();
    const dupeLabels = new Set<string>();
    for (const ws of this.workspaces()) {
      if (labels.has(ws.label)) {
        dupeLabels.add(ws.label);
      }
      labels.add(ws.label);
    }
    return dupeLabels.size > 0;
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
