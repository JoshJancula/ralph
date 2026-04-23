// @vitest-environment node

import '@angular/compiler';
import { PLATFORM_ID, createEnvironmentInjector, runInInjectionContext } from '@angular/core';

import { AppComponent } from './app.component';
import { NavService } from './services/nav.service';

describe('AppComponent SSR safety', () => {
  it('can be instantiated without window present', () => {
    const injector = createEnvironmentInjector([
      { provide: PLATFORM_ID, useValue: 'server' },
      { provide: NavService, useValue: { refresh: vi.fn() } },
    ]);

    const app = runInInjectionContext(injector, () => new AppComponent());

    expect(app).toBeTruthy();
    expect(app.isLightTheme()).toBe(false);
  });
});
