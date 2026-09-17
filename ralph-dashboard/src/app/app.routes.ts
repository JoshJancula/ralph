import { Component, computed, inject } from '@angular/core';
import { Routes } from '@angular/router';
import { FileViewerComponent } from './components/file-viewer/file-viewer.component';
import { GraphHubComponent } from './components/graph-hub/graph-hub.component';
import { HomeHubComponent } from './components/home-hub/home-hub.component';
import { LogViewerComponent } from './components/log-viewer/log-viewer.component';
import { PlanHubComponent } from './components/plan-hub/plan-hub.component';
import { RunsHubComponent } from './components/runs-hub/runs-hub.component';
import { UsageHubComponent } from './components/usage-hub/usage-hub.component';
import { DocsHubComponent } from './components/docs-hub/docs-hub.component';
import { PlanLogsComponent } from './components/plan-logs/plan-logs.component';
import { WorkflowStageLogsPageComponent } from './workflows/workflow-stage-logs.page';
import { NavService } from './services/nav.service';
import { workflowEditCanDeactivate } from './workflows/workflow-edit.guard';

@Component({
  selector: 'app-workspace-view',
  standalone: true,
  imports: [FileViewerComponent, GraphHubComponent, HomeHubComponent, LogViewerComponent, PlanHubComponent, RunsHubComponent, UsageHubComponent],
  template: `
    <div class="inventory-panes">
      <section class="workspace-pane" [hidden]="viewKind() !== 'home'">
        <ralph-home-hub [paneActive]="viewKind() === 'home'"></ralph-home-hub>
      </section>
      <section class="workspace-pane" [hidden]="viewKind() !== 'plan'">
        <ralph-plan-hub [paneActive]="viewKind() === 'plan'"></ralph-plan-hub>
      </section>
      <section class="workspace-pane" [hidden]="viewKind() !== 'runs'">
        <ralph-runs-hub [paneActive]="viewKind() === 'runs'"></ralph-runs-hub>
      </section>
      <section class="workspace-pane" [hidden]="viewKind() !== 'usage'">
        <ralph-usage-hub [paneActive]="viewKind() === 'usage'"></ralph-usage-hub>
      </section>
      <section class="workspace-pane" [hidden]="viewKind() !== 'graph-runs'">
        <ralph-graph-hub [paneActive]="viewKind() === 'graph-runs'"></ralph-graph-hub>
      </section>
    </div>

    @switch (viewKind()) {
      @case ('home') {
      }
      @case ('plan') {
      }
      @case ('runs') {
      }
      @case ('usage') {
      }
      @case ('graph-runs') {
      }
      @case ('browse') {
        <div class="browse-state">
          @if (activeRoot(); as root) {
            @switch (root) {
              @case ('docs') {
                <p class="browse-title">Docs</p>
                <p class="browse-body">
                  Choose a file in the sidebar under Docs for this workspace, or expand another project to browse its
                  documentation tree.
                </p>
              }
              @case ('logs') {
                <p class="browse-title">Logs</p>
                <p class="browse-body">Expand Logs in the sidebar and pick a log file to open it here.</p>
              }
              @case ('artifacts') {
                <p class="browse-title">Artifacts</p>
                <p class="browse-body">Expand Artifacts in the sidebar and select a file to preview it here.</p>
              }
              @case ('sessions') {
                <p class="browse-title">Sessions</p>
                <p class="browse-body">Expand Sessions in the sidebar and open a file to view it here.</p>
              }
              @case ('orchestration-plans') {
                <p class="browse-title">Orchestration plans</p>
                <p class="browse-body">Expand Orchestration plans in the sidebar and pick a plan file.</p>
              }
              @default {
                <p class="browse-title">Browse</p>
                <p class="browse-body">Pick a file from the sidebar to inspect it here.</p>
              }
            }
          }
        </div>
      }
      @case ('file') {
        @if (activeRoot(); as root) {
          @if (activeFile(); as file) {
            <app-file-viewer [root]="root" [filePath]="file"></app-file-viewer>
          }
        }
      }
      @case ('log') {
        @if (activeRoot(); as root) {
          @if (activeFile(); as file) {
            <ralph-log-viewer [root]="root" [filePath]="file"></ralph-log-viewer>
          }
        }
      }
      @default {
        @if (viewKind() === 'empty') {
          @if (activeRoot()) {
            <div class="empty-state">Select a file to inspect its contents.</div>
          } @else {
            <div class="empty-state">Select a section from the sidebar to get started.</div>
          }
        }
      }
    }
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
      flex-direction: column;
    }

    .inventory-panes {
      display: contents;
    }

    .workspace-pane {
      display: flex;
      flex: 1;
      flex-direction: column;
      min-height: 0;
      min-width: 0;
    }

    .workspace-pane[hidden] {
      display: none !important;
    }

    .empty-state {
      min-height: 0;
    }

    .browse-state {
      display: flex;
      flex: 1;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 0;
      gap: 0.75rem;
      max-width: 32rem;
      margin: 0 auto;
      padding: 2rem 1.5rem;
      text-align: center;
      background: var(--surface);
      border-radius: 8px;
      border: 1px solid var(--border);
    }

    .browse-title {
      margin: 0;
      font-size: 1.05rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .browse-body {
      margin: 0;
      font-size: 0.9rem;
      line-height: 1.45;
      color: var(--text-muted);
    }
  `,
})
export class WorkspaceViewComponent {
  private readonly nav = inject(NavService);
  readonly activeRoot = this.nav.activeRoot;
  readonly activeFile = this.nav.activeFile;
  readonly viewKind = computed<'home' | 'plan' | 'runs' | 'usage' | 'graph-runs' | 'file' | 'log' | 'browse' | 'empty'>(() => {
    const root = this.activeRoot();
    const file = this.activeFile();

    if (!root) {
      return 'empty';
    }
    if (file) {
      return file.endsWith('.log') ? 'log' : 'file';
    }
    if (root === 'home') {
      return 'home';
    }
    if (root === 'plans') {
      return 'plan';
    }
    if (root === 'runs') {
      return 'runs';
    }
    if (root === 'usage' || root === 'insights') {
      return 'usage';
    }
    if (root === 'graph-runs') {
      return 'graph-runs';
    }
    if (
      root === 'docs' ||
      root === 'logs' ||
      root === 'artifacts' ||
      root === 'sessions' ||
      root === 'orchestration-plans'
    ) {
      return 'browse';
    }
    return 'empty';
  });
}

/** Docs index and in-app doc files share one section; file URLs use `/docs/file/...`. */
@Component({
  selector: 'app-docs-shell',
  standalone: true,
  imports: [DocsHubComponent, FileViewerComponent],
  template: `
    @if (nav.activeFile(); as file) {
      <app-file-viewer root="docs" [filePath]="file"></app-file-viewer>
    } @else {
      <ralph-docs-hub></ralph-docs-hub>
    }
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
      flex-direction: column;
    }
  `,
})
export class DocsShellComponent {
  readonly nav = inject(NavService);
}

export const routes: Routes = [
  {
    path: '',
    pathMatch: 'full',
    redirectTo: 'home',
  },
  {
    path: 'home',
    component: WorkspaceViewComponent,
  },
  {
    path: 'runs',
    component: WorkspaceViewComponent,
  },
  {
    path: 'plans',
    component: WorkspaceViewComponent,
  },
  {
    path: 'plan-detail/:file/logs',
    component: PlanLogsComponent,
  },
  {
    path: 'plan-detail/:file',
    loadComponent: () => import('./components/plan-detail/plan-detail.component').then((m) => m.PlanDetailComponent),
  },
  {
    path: 'insights',
    component: WorkspaceViewComponent,
  },
  {
    path: 'usage',
    component: WorkspaceViewComponent,
  },
  {
    path: 'docs',
    component: DocsShellComponent,
  },
  {
    path: 'workflows',
    loadComponent: () => import('./workflows/workflows-list.page').then((m) => m.WorkflowsListPageComponent),
  },
  {
    path: 'tasks',
    pathMatch: 'full',
    redirectTo: 'tasks/active-board',
  },
  {
    path: 'tasks/:taskView',
    loadComponent: () => import('./tasks/tasks.page').then((m) => m.TasksPageComponent),
  },
  {
    path: 'schedules',
    loadComponent: () => import('./schedules/schedules.page').then((m) => m.SchedulesPageComponent),
  },
  {
    path: 'safety',
    loadComponent: () => import('./safety/safety.page').then((m) => m.SafetyPageComponent),
  },
  {
    path: 'workflows/new',
    loadComponent: () => import('./workflows/workflow-new.page').then((m) => m.WorkflowNewPageComponent),
  },
  {
    path: 'workflows/runs/:runId/stages/:stageId/logs',
    component: WorkflowStageLogsPageComponent,
  },
  {
    path: 'workflows/runs/:runId',
    loadComponent: () => import('./workflows/workflow-run-detail.page').then((m) => m.WorkflowRunDetailPageComponent),
  },
  {
    path: 'workflows/:id',
    loadComponent: () => import('./workflows/workflow-detail.page').then((m) => m.WorkflowDetailPageComponent),
  },
  {
    path: 'workflows/:id/edit',
    loadComponent: () => import('./workflows/workflow-edit.page').then((m) => m.WorkflowEditPageComponent),
    canDeactivate: [workflowEditCanDeactivate],
  },
  {
    path: ':root/path/:path/file/:file',
    component: WorkspaceViewComponent,
  },
  {
    path: ':root/file/:file',
    component: WorkspaceViewComponent,
  },
  {
    path: ':root/path/:path',
    component: WorkspaceViewComponent,
  },
  {
    path: ':root',
    component: WorkspaceViewComponent,
  },
  {
    path: '**',
    redirectTo: 'home',
  },
];
