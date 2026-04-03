import { CommonModule } from '@angular/common';
import { AfterViewChecked, Component, inject, signal } from '@angular/core';
import { FileViewerComponent } from './components/file-viewer/file-viewer.component';
import { LogViewerComponent } from './components/log-viewer/log-viewer.component';
import { PlanHubComponent } from './components/plan-hub/plan-hub.component';
import { WorkspaceSidebarComponent } from './components/workspace-sidebar/workspace-sidebar.component';
import { NavService } from './services/nav.service';
import mermaid from 'mermaid';

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
export class AppComponent implements AfterViewChecked {
  readonly nav = inject(NavService);
  readonly isLightTheme = signal(false);
  private mermaidInitialized = false;
  private mermaidTheme: 'base' | 'dark' | null = null;
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
    this.resetMermaidRendering();
  }

  ngAfterViewChecked(): void {
    this.renderMermaidDiagramsIfNeeded();
  }

  private renderMermaidDiagramsIfNeeded(): void {
    if (typeof document === 'undefined') {
      return;
    }

    if (!document.querySelector('.mermaid')) {
      return;
    }

    const nextTheme = this.isLightTheme() ? 'base' : 'dark';
    if (!this.mermaidInitialized || this.mermaidTheme !== nextTheme) {
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'loose',
        theme: nextTheme,
      });
      this.mermaidInitialized = true;
      this.mermaidTheme = nextTheme;
    }

    mermaid.contentLoaded();
  }

  private resetMermaidRendering(): void {
    this.mermaidInitialized = false;
    this.mermaidTheme = null;
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
