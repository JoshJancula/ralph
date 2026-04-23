import { Component, computed, inject } from '@angular/core';
import { Routes } from '@angular/router';
import { FileViewerComponent } from './components/file-viewer/file-viewer.component';
import { LogViewerComponent } from './components/log-viewer/log-viewer.component';
import { PlanHubComponent } from './components/plan-hub/plan-hub.component';
import { UsageHubComponent } from './components/usage-hub/usage-hub.component';
import { NavService } from './services/nav.service';

@Component({
  selector: 'app-workspace-view',
  standalone: true,
  imports: [FileViewerComponent, LogViewerComponent, PlanHubComponent, UsageHubComponent],
  template: `
    @switch (viewKind()) {
      @case ('plan') {
        <ralph-plan-hub></ralph-plan-hub>
      }
      @case ('usage') {
        <ralph-usage-hub></ralph-usage-hub>
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
  `,
})
export class WorkspaceViewComponent {
  private readonly nav = inject(NavService);
  readonly activeRoot = this.nav.activeRoot;
  readonly activeFile = this.nav.activeFile;
  readonly viewKind = computed<'plan' | 'usage' | 'file' | 'log' | 'empty'>(() => {
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
    return root === 'plans' ? 'plan' : 'empty';
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
