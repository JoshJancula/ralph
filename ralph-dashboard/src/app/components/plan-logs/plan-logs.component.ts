import { ChangeDetectionStrategy, Component, OnInit, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { firstValueFrom } from 'rxjs';
import { ApiService, ListingEntry, WorkspaceRegistry } from '../../services/api.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { ErrorModalComponent } from '../error-modal/error-modal.component';
import { PlanLogResolutionService } from '../../services/plan-log-resolution.service';

function normalizeProjectRoot(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/+$/, '');
}

@Component({
  selector: 'ralph-plan-logs',
  standalone: true,
  imports: [CommonModule, RouterLink, ErrorModalComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="plan-logs hub-page">
      <a class="back-link" [routerLink]="['/plan-detail', planPath()]" [queryParams]="{ projectRoot: projectRoot() }">Back to plan</a>
      <header class="page-header">
        <div>
          <h1 class="page-title">Plan logs</h1>
          <p class="page-lede">Runner, runtime, and verification logs for this leaf plan.</p>
        </div>
      </header>
      @if (loading()) {
        <p class="state">Loading logs…</p>
      } @else if (error()) {
        <div class="error-embed" role="alert">
          <ralph-error-modal class="is-embedded" [error]="error()" [embedded]="true" [showHeader]="false" />
        </div>
      } @else if (entries().length === 0) {
        <p class="state">No logs have been recorded for this plan yet.</p>
      } @else {
        <div class="log-list">
          @for (entry of entries(); track entry.path) {
            <a class="log-link" [routerLink]="['/logs', 'file', entry.path]" [queryParams]="{ workspaceRoot: workspaceRoot() }">
              <span>{{ entry.name }}</span>
              <span>{{ entry.path }}</span>
            </a>
          }
        </div>
      }
    </div>
  `,
  styles: `
    :host { display:flex; flex:1; min-height:0; }
    .plan-logs { background:var(--surface); }
    .state { color:var(--text-muted); }
    .error-embed { max-width: 40rem; }
    .log-list { display:grid; gap:var(--space-2); }
    .log-link {
      display:flex; justify-content:space-between; gap:var(--space-3);
      padding:var(--space-3) var(--space-4); border:1px solid var(--border);
      border-radius:var(--radius-md); color:var(--text-primary); text-decoration:none;
    }
    .log-link:hover { border-color:var(--accent); background:var(--surface-hover); }
    .log-link span:last-child { color:var(--text-muted); font-family:var(--monospace-font); font-size:var(--font-size-xs); }
  `,
})
export class PlanLogsComponent implements OnInit {
  private readonly api = inject(ApiService);
  private readonly route = inject(ActivatedRoute);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);
  private readonly planLogResolution = inject(PlanLogResolutionService);

  readonly entries = signal<readonly ListingEntry[]>([]);
  readonly loading = signal(true);
  readonly error = signal<unknown>(null);
  readonly planPath = signal('');
  readonly projectRoot = signal<string | null>(null);
  readonly workspaceRoot = signal<string | null>(null);

  async ngOnInit(): Promise<void> {
    const planPath = this.route.snapshot.paramMap.get('file') ?? '';
    const projectRoot = this.route.snapshot.queryParamMap.get('projectRoot');
    this.planPath.set(planPath);
    this.projectRoot.set(projectRoot);

    try {
      const workspaces = await firstValueFrom(this.api.fetchWorkspaces());
      const workspace = this.resolveWorkspace(workspaces, projectRoot);
      if (!workspace) {
        throw new Error(
          projectRoot
            ? 'The plan workspace is unavailable for the selected project.'
            : 'Select a project before opening plan logs, or open the plan from the inventory so its project is known.',
        );
      }

      if (this.workspaceSelector.selectedWorkspacePath() !== workspace.projectRoot) {
        this.workspaceSelector.selectWorkspace(workspace.projectRoot);
      }

      this.workspaceRoot.set(workspace.workspaceRoot);
      this.projectRoot.set(workspace.projectRoot);

      const normalizedPath = planPath.replace(/\\/g, '/');
      const planKey = normalizedPath.slice(normalizedPath.lastIndexOf('/') + 1).replace(/\.md$/i, '');
      const listing = await firstValueFrom(this.api.fetchListing('logs', planKey, workspace.workspaceRoot));
      this.entries.set(await this.collectLogFiles(listing.entries, planKey, workspace.workspaceRoot));
    } catch (error) {
      this.error.set(error);
    } finally {
      this.loading.set(false);
    }
  }

  private resolveWorkspace(
    workspaces: readonly WorkspaceRegistry[],
    projectRoot: string | null,
  ): WorkspaceRegistry | undefined {
    if (projectRoot) {
      const target = normalizeProjectRoot(projectRoot);
      return workspaces.find((item) => normalizeProjectRoot(item.projectRoot) === target);
    }

    const selected = this.workspaceSelector.selectedWorkspacePath();
    if (selected) {
      const target = normalizeProjectRoot(selected);
      return workspaces.find((item) => normalizeProjectRoot(item.projectRoot) === target);
    }

    // Do not fall back to workspaces[0] when in All-projects mode — that scopes
    // logs to the wrong (often first/global) registry entry.
    return undefined;
  }

  private async collectLogFiles(
    entries: readonly ListingEntry[],
    planKey: string,
    workspaceRoot: string,
  ): Promise<ListingEntry[]> {
    const files = entries.filter((entry) => entry.type === 'file');
    if (files.length > 0) {
      return [...files].sort((a, b) => b.mtime - a.mtime);
    }

    // Nested run dirs (e.g. run-*/output.log) — reuse resolution to find latest,
    // then list one level of subdirectory files for the inventory page.
    const target = await firstValueFrom(this.planLogResolution.resolveLatestLogTarget(planKey, workspaceRoot));
    if (target.file) {
      const name = target.file.slice(target.file.lastIndexOf('/') + 1);
      return [
        {
          name,
          path: target.file,
          type: 'file',
          size: 0,
          mtime: Date.now(),
        },
      ];
    }

    const nested: ListingEntry[] = [];
    const dirs = entries
      .filter((entry) => entry.type === 'dir')
      .sort((a, b) => b.mtime - a.mtime);
    for (const dir of dirs.slice(0, 5)) {
      try {
        const sub = await firstValueFrom(this.api.fetchListing('logs', dir.path, workspaceRoot));
        nested.push(...sub.entries.filter((entry) => entry.type === 'file'));
      } catch {
        // Skip unreadable nested dirs; keep collecting others.
      }
    }
    return nested.sort((a, b) => b.mtime - a.mtime);
  }
}
