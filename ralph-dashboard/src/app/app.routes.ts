import { Component, computed, inject } from '@angular/core';
import { Routes } from '@angular/router';
import { FileViewerComponent } from './components/file-viewer/file-viewer.component';
import { GraphHubComponent } from './components/graph-hub/graph-hub.component';
import { LogViewerComponent } from './components/log-viewer/log-viewer.component';
import { PlanHubComponent } from './components/plan-hub/plan-hub.component';
import { UsageHubComponent } from './components/usage-hub/usage-hub.component';
import { NavService } from './services/nav.service';

@Component({
  selector: 'app-workspace-view',
  standalone: true,
  imports: [FileViewerComponent, GraphHubComponent, LogViewerComponent, PlanHubComponent, UsageHubComponent],
  template: `
    @switch (viewKind()) {
      @case ('plan') {
        <ralph-plan-hub></ralph-plan-hub>
      }
      @case ('usage') {
        <ralph-usage-hub></ralph-usage-hub>
      }
      @case ('graph-runs') {
        <ralph-graph-hub></ralph-graph-hub>
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
        @if (activeRoot()) {
          <div class="empty-state">Select a file to inspect its contents.</div>
        } @else {
          <div class="empty-state">Select a section from the sidebar to get started.</div>
        }
      }
    }
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
    }

    .empty-state {
      display: flex;
      flex: 1;
      align-items: center;
      justify-content: center;
      min-height: 0;
      color: var(--text-muted);
      font-size: 0.9rem;
      text-align: center;
      padding: 2rem;
      background: var(--surface);
      border-radius: 8px;
      border: 1px solid var(--border);
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
  readonly viewKind = computed<'plan' | 'usage' | 'graph-runs' | 'file' | 'log' | 'browse' | 'empty'>(() => {
    const root = this.activeRoot();
    const file = this.activeFile();

    if (!root) {
      return 'empty';
    }
    if (file) {
      return file.endsWith('.log') ? 'log' : 'file';
    }
    if (root === 'usage') {
      return 'usage';
    }
    if (root === 'plans') {
      return 'plan';
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

export const routes: Routes = [
  {
    path: '',
    pathMatch: 'full',
    redirectTo: 'plans',
  },
  {
    path: 'plans',
    component: WorkspaceViewComponent,
  },
  {
    path: 'usage',
    component: WorkspaceViewComponent,
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
    redirectTo: 'plans',
  },
];
