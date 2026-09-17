import { isPlatformBrowser } from '@angular/common';
import { Component, OnInit, PLATFORM_ID, computed, inject, signal } from '@angular/core';
import { Title } from '@angular/platform-browser';
import { NavigationEnd, Router, RouterOutlet } from '@angular/router';
import {
  IonApp,
  IonButton,
  IonButtons,
  IonContent,
  IonHeader,
  IonIcon,
  IonMenu,
  IonMenuButton,
  IonSplitPane,
  IonTitle,
  IonToolbar,
  MenuController,
} from '@ionic/angular/standalone';
import { addIcons } from 'ionicons';
import {
  menuOutline,
  moonOutline,
  refreshOutline,
  statsChartOutline,
  sunnyOutline,
} from 'ionicons/icons';
import { WorkspaceSidebarComponent } from './components/workspace-sidebar/workspace-sidebar.component';
import { WorkspaceSwitcherComponent } from './components/workspace-switcher/workspace-switcher.component';
import { AssistantDockComponent } from './assistant/assistant-dock.component';
import { NavService } from './services/nav.service';
import { NavPerfService } from './services/nav-perf.service';
import { filter } from 'rxjs';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [
    WorkspaceSidebarComponent,
    WorkspaceSwitcherComponent,
    AssistantDockComponent,
    RouterOutlet,
    IonApp,
    IonSplitPane,
    IonMenu,
    IonHeader,
    IonToolbar,
    IonTitle,
    IonButtons,
    IonButton,
    IonIcon,
    IonMenuButton,
    IonContent,
  ],
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.scss'],
})
export class AppComponent implements OnInit {
  static readonly WORKSPACE_MENU_ID = 'workspace-menu';

  readonly nav = inject(NavService);
  /** Eagerly construct so navigation marks are registered in development. */
  private readonly _navPerf = inject(NavPerfService);
  readonly headerTitle = computed(() => {
    const section = this.nav.activeSection();
    switch (section) {
      case 'home':
        return 'Home';
      case 'runs':
        return 'Runs';
      case 'plans':
        return 'Plans';
      case 'workflows':
        return 'Workflows';
      case 'tasks':
        return 'Tasks';
      case 'schedules':
        return 'Schedules';
      case 'insights':
        return 'Insights';
      case 'browse':
        return 'Workspace Explorer';
      default:
        return 'Ralph Dashboard';
    }
  });
  readonly isLightTheme = signal(false);
  private readonly platformId = inject(PLATFORM_ID);
  private readonly pageTitle = inject(Title, { optional: true });
  private readonly router = inject(Router, { optional: true });
  private readonly menuController = inject(MenuController);
  private static readonly THEME_STORAGE_KEY = 'ralph-dashboard-theme';

  constructor() {
    addIcons({
      menuOutline,
      refreshOutline,
      statsChartOutline,
      sunnyOutline,
      moonOutline,
    });
  }

  skipToContent(event: Event): void {
    event.preventDefault();
    const main = document.getElementById('main-content');
    main?.focus();
  }

  ngOnInit(): void {
    if (!isPlatformBrowser(this.platformId)) {
      return;
    }

    this.initializeTheme();
    this.syncDocumentTitle();
    this.router?.events.pipe(filter((event) => event instanceof NavigationEnd)).subscribe(() => {
      this.syncDocumentTitle();
      void this.closeWorkspaceMenuAfterNavigation();
    });
  }

  /** Dismisses the overlay drawer on narrow viewports after in-app navigation. */
  private closeWorkspaceMenuAfterNavigation(): void {
    if (!isPlatformBrowser(this.platformId)) {
      return;
    }
    void this.menuController.close(AppComponent.WORKSPACE_MENU_ID);
  }

  private syncDocumentTitle(): void {
    this.pageTitle?.setTitle(`${this.headerTitle()} · Ralph`);
  }

  refresh(): void {
    this.nav.refresh();
  }

  navigateToInsights(): void {
    this.nav.navigate('insights');
  }

  toggleTheme(): void {
    const next = !this.isLightTheme();
    this.isLightTheme.set(next);

    this.applyThemeClass(next);
    this.storeThemePreference(next);
  }

  private initializeTheme(): void {
    const storedPreference = this.readStoredThemePreference();
    // Ralph is intentionally dark-first. A stored preference always wins,
    // while new visitors start in the operational dark theme regardless of
    // the host operating-system preference.
    const initialTheme = storedPreference ?? false;

    this.isLightTheme.set(initialTheme);
    this.applyThemeClass(initialTheme);
  }

  private readStoredThemePreference(): boolean | undefined {
    if (typeof window === 'undefined') {
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
    if (typeof window === 'undefined') {
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

}
