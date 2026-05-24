// @vitest-environment node

import '@angular/compiler';
import { PLATFORM_ID, createEnvironmentInjector, runInInjectionContext, signal } from '@angular/core';
import { of } from 'rxjs';

import { AppComponent } from './app.component';
import { ApiService } from './services/api.service';
import { NavService } from './services/nav.service';
import { WorkspaceSelectorService } from './services/workspace-selector.service';

describe('AppComponent SSR safety', () => {
  it('can be instantiated without window present', () => {
    const injector = createEnvironmentInjector([
      { provide: PLATFORM_ID, useValue: 'server' },
      { provide: NavService, useValue: { refresh: vi.fn(), navigate: vi.fn() } },
      {
        provide: WorkspaceSelectorService,
        useValue: {
          workspaces: signal([]),
          selectedWorkspacePath: signal<string | null>(null),
          loadWorkspaces: vi.fn(),
          selectWorkspace: vi.fn(),
        },
      },
      {
        provide: ApiService,
        useValue: {
          fetchRalphFrameworkProjectRoot: () => of({ projectRoot: null }),
        },
      },
    ]);

    const app = runInInjectionContext(injector, () => new AppComponent());

    expect(app).toBeTruthy();
    expect(app.isLightTheme()).toBe(false);
  });
});
