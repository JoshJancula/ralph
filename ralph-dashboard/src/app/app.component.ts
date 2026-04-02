import { CommonModule } from '@angular/common';
import { Component, inject, signal } from '@angular/core';
import { FileViewerComponent } from './components/file-viewer/file-viewer.component';
import { LogViewerComponent } from './components/log-viewer/log-viewer.component';
import { PlanHubComponent } from './components/plan-hub/plan-hub.component';
import { WorkspaceSidebarComponent } from './components/workspace-sidebar/workspace-sidebar.component';
import { NavService } from './services/nav.service';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [
    CommonModule,
    FileViewerComponent,
    LogViewerComponent,
    PlanHubComponent,
    WorkspaceSidebarComponent,
  ],
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.scss'],
})
export class AppComponent {
  readonly nav = inject(NavService);
  readonly isLightTheme = signal(false);

  constructor() {
    if (typeof document !== 'undefined') {
      this.isLightTheme.set(document.body.classList.contains('theme-light'));
    }
  }

  refresh(): void {
    this.nav.refresh();
  }

  toggleTheme(): void {
    const next = !this.isLightTheme();
    this.isLightTheme.set(next);

    if (typeof document !== 'undefined') {
      document.body.classList.toggle('theme-light', next);
    }
  }
}
