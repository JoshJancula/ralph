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
  private static readonly THEME_STORAGE_KEY = 'ralph-dashboard-theme';

  constructor() {
    const storedPreference = this.readStoredThemePreference();
    const prefersLight = this.prefersLightColorScheme();
    const initialTheme = storedPreference ?? prefersLight;
    this.isLightTheme.set(initialTheme);

    if (typeof document !== 'undefined') {
      this.applyThemeClass(initialTheme);
    }
  }

  refresh(): void {
    this.nav.refresh();
  }

  toggleTheme(): void {
    const next = !this.isLightTheme();
    this.isLightTheme.set(next);

    if (typeof document !== 'undefined') {
      this.applyThemeClass(next);
    }
    this.storeThemePreference(next);
  }

  private readStoredThemePreference(): boolean | undefined {
    if (typeof window === 'undefined' || typeof window.localStorage === 'undefined') {
      return undefined;
    }

    const item = window.localStorage.getItem(AppComponent.THEME_STORAGE_KEY);
    if (item === 'light') {
      return true;
    }
    if (item === 'dark') {
      return false;
    }

    return undefined;
  }

  private storeThemePreference(isLight: boolean): void {
    if (typeof window === 'undefined' || typeof window.localStorage === 'undefined') {
      return;
    }

    window.localStorage.setItem(
      AppComponent.THEME_STORAGE_KEY,
      isLight ? 'light' : 'dark',
    );
  }

  private applyThemeClass(isLight: boolean): void {
    if (typeof document === 'undefined') {
      return;
    }

    document.body.classList.toggle('theme-light', isLight);
  }

  private prefersLightColorScheme(): boolean {
    if (typeof window === 'undefined' || typeof window.matchMedia === 'undefined') {
      return false;
    }

    return window.matchMedia('(prefers-color-scheme: light)').matches;
  }
}
