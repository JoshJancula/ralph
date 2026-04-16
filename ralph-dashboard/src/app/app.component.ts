import { isPlatformBrowser } from '@angular/common';
import { Component, OnInit, PLATFORM_ID, inject, signal } from '@angular/core';
import { RouterOutlet } from '@angular/router';
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
} from '@ionic/angular/standalone';
import { addIcons } from 'ionicons';
import { menuOutline, refreshOutline, sunnyOutline, moonOutline } from 'ionicons/icons';
import { WorkspaceSidebarComponent } from './components/workspace-sidebar/workspace-sidebar.component';
import { NavService } from './services/nav.service';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [
    WorkspaceSidebarComponent,
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
  readonly nav = inject(NavService);
  readonly isLightTheme = signal(false);
  private readonly platformId = inject(PLATFORM_ID);
  private static readonly THEME_STORAGE_KEY = 'ralph-dashboard-theme';

  constructor() {
    addIcons({ menuOutline, refreshOutline, sunnyOutline, moonOutline });
  }

  ngOnInit(): void {
    if (!isPlatformBrowser(this.platformId)) {
      return;
    }

    this.initializeTheme();
  }

  refresh(): void {
    this.nav.refresh();
  }

  toggleTheme(): void {
    const next = !this.isLightTheme();
    this.isLightTheme.set(next);

    this.applyThemeClass(next);
    this.storeThemePreference(next);
  }

  private initializeTheme(): void {
    const storedPreference = this.readStoredThemePreference();
    const prefersLight = this.prefersLightColorScheme();
    const initialTheme = storedPreference ?? prefersLight;

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

  private prefersLightColorScheme(): boolean {
    if (typeof window === 'undefined' || typeof window.matchMedia === 'undefined') {
      return false;
    }

    return window.matchMedia('(prefers-color-scheme: light)').matches;
  }

}
